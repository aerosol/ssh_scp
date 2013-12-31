%%% @author Søren Hilmer <sh@widetrail.dk>
%%% @copyright (C) 2013, Søren Hilmer
%%% @doc
%%% ssh_scp module implementing client side scp (Secure CoPy) in Erlang
%%% @end
%%% Created : 25 Dec 2013 by Søren Hilmer <sh@widetrail.dk>

-module(ssh_scp).

-include_lib("kernel/include/file.hrl").
-include_lib("ssh/src/ssh_connect.hrl").


-include("include/ssh_scp_opts.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include("test_setup/localhost_connection.hrl").
-endif.

-export([to/3,to/4]).

%%--------------------------------------------------------------------
%% @doc copies the file in Filename to the remote and place it in Destination 
%% using the supplied ssh connection, ConnectionRef. With default transfer options
%%
%% @spec to(ConnectionRef, Filename, Destination) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------

to(ConnectionRef, Filename, Destination) ->
    ssh_scp:to(ConnectionRef, Filename, Destination,#ssh_scp_opts{timeout=30000}).

%%--------------------------------------------------------------------
%% @doc copies the file in Filename to the remote and place it in Destination, 
%% which must be an existing directory on the remote side,
%% using the supplied ssh connection, ConnectionRef. The file will end up with 
%% Permission specified in the String Permission and giving up after timeout
%%
%% @spec to(ConnectionRef, Filename, Destination, Permission, Timeout) -> ok | {error, Reason}
%% @end
%%--------------------------------------------------------------------
to(ConnectionRef, Filename, Destination, Opts) when is_record(Opts, ssh_scp_opts) ->
    Timeout = case Opts#ssh_scp_opts.timeout of undefined -> 30000; T -> T end,
    case (file:read_file_info(Filename)) of 
      {ok, FileInfo} ->
            Permission = file_mode_to_permission_string(FileInfo#file_info.mode),
            case FileInfo#file_info.type of
                regular ->
                    with_transfer_channel(
                      ConnectionRef,Timeout, Destination,
                      fun(ChannelId) -> 
                              case send_file(ConnectionRef,ChannelId,Filename,Permission,FileInfo#file_info.size) of 
                                  ok -> send_eof(ConnectionRef,ChannelId);
                                  Err -> Err
                              end
                      end);
                directory -> 
                    with_transfer_channel(
                      ConnectionRef,Timeout, Destination,
                      fun(ChannelId) ->
                              Name = filename:basename(Filename),
                              case send_dir_start(ConnectionRef,ChannelId,Name,Permission,FileInfo) of
                                  ok ->
                                      case send_dir(ConnectionRef,ChannelId,Filename) of
                                          ok -> case send_dir_end(ConnectionRef, ChannelId, Name) of
                                                    ok -> send_eof(ConnectionRef,ChannelId);
                                                    Err1 -> Err1
                                                end;
                                          Err2 -> Err2
                                      end;
                                  Err3 -> Err3
                              end
                      end);
                Other_File_Type -> {error, list_to_binary(io_lib:format("Cannot transder file type ~p",[Other_File_Type]))}
            end;
        {error, Reason1} -> {error, Reason1}
    end.

%%--------------------------------------------------------------------  
%% Traverse directory structure recursively. And transfer files
%%--------------------------------------------------------------------  
send_dir(ConnectionRef,ChannelId,Dir) ->
    traverse_abs(ConnectionRef,ChannelId,filename:absname(Dir)).
    
traverse_abs(ConnectionRef,ChannelId,Dir) ->
    {ok, Filenames} = file:list_dir(Dir),
    F = fun(Name) ->
                AbsName = filename:absname_join(Dir,Name),
                case file:read_file_info(AbsName) of
                    {ok, FileInfo} ->
                        Permission = file_mode_to_permission_string(FileInfo#file_info.mode),
                        case  FileInfo#file_info.type of
                            directory  -> 
                                io:format("enter Dir ~s~n",[Name]),
                                send_dir_start(ConnectionRef,ChannelId,Name,Permission,FileInfo),
                                traverse_abs(ConnectionRef,ChannelId,AbsName),
                                send_dir_end(ConnectionRef,ChannelId,Name);
                            regular -> send_file(ConnectionRef,ChannelId,AbsName,Permission,FileInfo#file_info.size);
                            Other_File_Type -> {error, list_to_binary(io_lib:format("Cannot transder file type ~p",[Other_File_Type]))}
                        end;
                    {error, Reason1} -> {error, Reason1}
                end
        end,
    lists:foreach(F, Filenames).

send_dir_start(ConnectionRef,ChannelId,Name,Permission,Fi) ->
    io:format("enter Dir ~s, perm ~p ~p ~n",[Name,Permission,Fi#file_info.mode]),
    send_content(ConnectionRef,ChannelId,
                 fun() ->
                         %%send header
                         Header = list_to_binary(lists:flatten(io_lib:format("D~s ~p ~s~n",[Permission, 0, Name]))),
                         io:format("start dir header ~s~n",[Header]),
                         ssh_connection:send(ConnectionRef, ChannelId, Header)
                 end).
    
send_dir_end(ConnectionRef, ChannelId, _Name) ->
    io:format("exit Dir ~s~n",[_Name]),
    send_content(ConnectionRef,ChannelId,
                 fun() ->
                         %%send end dir
                         Header = list_to_binary(lists:flatten(io_lib:format("E~n",[]))),
                         io:format("end dir header ~s~n",[Header]),
                         ssh_connection:send(ConnectionRef, ChannelId, Header)
                 end).

send_file(ConnectionRef,ChannelId,Name,Permission,Size) ->
    
    case file:open(Name, [read, binary, raw]) of
        {ok, Handle} -> 
            case send_content(ConnectionRef,ChannelId,
                         fun() ->
                                 %%send header
                                 Header = list_to_binary(lists:flatten(io_lib:format("C~s ~p ~s~n",[Permission, Size, filename:basename(Name)]))),
                                 io:format("file header ~s~n",[Header]),
                                 ssh_connection:send(ConnectionRef, ChannelId, Header)
                         end) of 
                ok -> TransferResult = send_file_in_chunks(ConnectionRef,ChannelId,Handle),
                      file:close(Handle),
                      TransferResult
            end;
        {error, Reason2} -> {error, Reason2}
    end.

send_file_in_chunks(ConnectionRef,ChannelId,Handle) ->
    case file:read(Handle, ?DEFAULT_PACKET_SIZE) of %% use packetsize as chunksize
        {ok, Content} -> 
            case send_content(ConnectionRef,ChannelId,
                              fun() ->
                                      %%ok send file
                                      io:format("file content ~n",[]),
                                      ssh_connection:send(ConnectionRef, ChannelId, Content)
                              end) of
                ok -> send_file_in_chunks(ConnectionRef,ChannelId,Handle);
                Err -> Err
            end;
        eof -> ssh_connection:send(ConnectionRef, ChannelId, <<"\0">>)
    end.

%%
%% Actually does final receive of 0 byte, thereby honouring end of transfer
%%
send_eof(ConnectionRef,ChannelId) ->
    send_content(ConnectionRef,ChannelId, fun() -> ok end).
    
    
%%--------------------------------------------------------------------
%% @doc
%% implements the actual file transfer to the remote side
%% @end
%%--------------------------------------------------------------------
send_content(ConnectionRef,ChannelId,Transfer) ->
    receive
        {ssh_cm, ConnectionRef, Msg} ->
            case Msg of
                {closed, _ChannelId} ->
                    ssh_connection:close(ConnectionRef, ChannelId), ok;
                {eof, _ChannelId} -> 
                    ssh_connection:close(ConnectionRef, ChannelId),
                    {error, <<"Error: EOF">>};
                {exit_signal, _ChannelId, ExitSignal, ErrorMsg, _LanguageString} ->
                    ssh_connection:close(ConnectionRef, ChannelId),
                    {error, list_to_binary(io_lib:format("Remote SCP exit signal: ~p : ~p",[ExitSignal,ErrorMsg]))};
                {exit_status,_ChannelId,ExitStatus} ->
                    ssh_connection:close(ConnectionRef, ChannelId),
                    case ExitStatus of
                        0 -> ok;
                        _ -> {error, list_to_binary(io_lib:format("Remote SCP exit status: ~p",[ExitStatus]))}
                    end;
                {data,_ChannelId,_Type,<<1,ErrorRest/binary>>} ->
                    {error, ErrorRest};
                {data,ChannelId,_Type,<<0>>} ->
                    Transfer()
            end
    end.  


%%--------------------------------------------------------------------
%% @doc
%% establish channel
%% @end
%%--------------------------------------------------------------------
with_transfer_channel(ConnectionRef, Timeout, Destination, F) ->
    case ssh_connection:session_channel(ConnectionRef, Timeout) of
        {ok, ChannelId} ->
            Cmd = lists:flatten(io_lib:format("scp -trq ~s",[Destination])),
            case ssh_connection:exec(ConnectionRef, ChannelId, Cmd, Timeout) of 
                success ->
                    F(ChannelId);
                failure -> 
                    {error, <<"Failed to execute remote scp">>}
            end;
        {error, Reason} -> {error, Reason}
    end.
    
file_mode_to_permission_string(Mode) when is_atom(Mode) ->
    undefined;
file_mode_to_permission_string(Mode) when is_integer(Mode), Mode >= 0, Mode =< 65535 ->
    <<_H1:4,H:3,O:3,G:3,R:3>> = <<Mode:16>>,
    lists:concat(io_lib:format("~B~B~B~B",[H,O,G,R])).



%%--------------------------------------------------------------------
%% TEST functions
%%--------------------------------------------------------------------
-ifdef(TEST).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.

start_dependencies() ->
    ensure_started(asn1),
    ensure_started(public_key),
    ensure_started(crypto),
    ensure_started(ssh).

setup() ->
    start_dependencies(),
    ok = file:make_dir("DirA"),
    ok = file:write_file("DirA/FileA", "filea"),
    ok = file:make_dir("DirA/DirB"),
    ok = file:write_file("DirA/DirB/FileB", "fileb"),
    ok = file:make_dir("DirA/DirC"),
    ok = file:make_dir("DirA/DirC/DirD"),
    ok = file:write_file("DirA/DirC/DirD/FileD", "filed"),
    ssh:connect("localhost",22, ?LOCALHOST_PARAMS, 30000).
    
cleanup(SSHConnection) ->
    ok = file:delete("DirA/DirC/DirD/FileD"),
    ok = file:del_dir("DirA/DirC/DirD"),
    ok = file:del_dir("DirA/DirC"),
    ok = file:delete("DirA/DirB/FileB"),
    ok = file:del_dir("DirA/DirB"),
    ok = file:delete("DirA/FileA"),
    ok = file:del_dir("DirA"),
    {ok,ConnectionRef} = SSHConnection,
    ssh:close(ConnectionRef).

to_test_() ->
    { setup,
      fun setup/0,
      fun cleanup/1,
      fun (SSHConnection) -> 
              [
               ?_test(to_remote_small_file(SSHConnection)),
               ?_test(to_remote_directory(SSHConnection))
              ]
      end
    }.


to_remote_small_file(SSHConnection) ->
    ?debugFmt("Working Dir ~p",[file:get_cwd()]),
    LocalFilename = "./hello",
    Content = <<"Hello SCP">>,
    ok = file:write_file(LocalFilename, Content),
    {ok, ConnectionRef} = SSHConnection,
    ?debugFmt("Connection established ~p",[ConnectionRef]),
    ok = ssh_scp:to(ConnectionRef, LocalFilename,"/tmp"),
    {ok, Content} = file:read_file("/tmp/"++filename:basename(LocalFilename)),
    ok = file:delete(LocalFilename).

to_remote_directory(SSHConnection) ->
    {ok, ConnectionRef} = SSHConnection,
    ?debugFmt("Connection established ~p",[ConnectionRef]),
    ok = ssh_scp:to(ConnectionRef, "DirA","/tmp").
    
    

-endif.

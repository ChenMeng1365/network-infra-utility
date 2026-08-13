-module(ssh_sftp_session).
-behaviour(gen_server).

%% SFTP session — manages a single SFTP channel on an SSH connection.
%%
%% Key design (LLD §6.6):
%%   - Each SFTP session is a gen_server, managed by ssh_sftp_sup
%%   - Single session = serial operations (no concurrent ops on same channel)
%%   - Concurrent transfers = multiple sftp_sessions on the same conn
%%   - Connection close → sftp_sup cleans up all sessions for that conn_id

-export([
    start_link/2,
    conn_id/1,
    get_id/1,
    rpc_list_dir/1,
    rpc_download/1,
    rpc_upload/1,
    rpc_mkdir/1,
    rpc_remove/1,
    rpc_stat/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("ssh_ipc.hrl").
-include_lib("kernel/include/file.hrl").

%% ---------- Public API ----------

%% @doc Start an SFTP session on an existing SSH connection.
start_link(ConnId, SshRef) ->
    gen_server:start_link(?MODULE, [ConnId, SshRef], []).

%% @doc Get the connection ID for this session.
conn_id(Pid) ->
    gen_server:call(Pid, conn_id).

%% @doc Get the sftp_id for this session.
get_id(Pid) ->
    gen_server:call(Pid, get_id).

%% @doc RPC handler for sftp.list_dir
rpc_list_dir(#{<<"sftp_id">> := SftpId, <<"path">> := Path}) ->
    case find_by_sftp_id(SftpId) of
        {ok, Pid} -> gen_server:call(Pid, {list_dir, Path});
        {error, not_found} -> {error, sftp_not_found}
    end.

%% @doc RPC handler for sftp.download
rpc_download(#{<<"sftp_id">> := SftpId, <<"remote">> := Remote, <<"local">> := Local}) ->
    case find_by_sftp_id(SftpId) of
        {ok, Pid} -> gen_server:call(Pid, {download, Remote, Local}, infinity);
        {error, not_found} -> {error, sftp_not_found}
    end.

%% @doc RPC handler for sftp.upload
rpc_upload(#{<<"sftp_id">> := SftpId, <<"local">> := Local, <<"remote">> := Remote}) ->
    case find_by_sftp_id(SftpId) of
        {ok, Pid} -> gen_server:call(Pid, {upload, Local, Remote}, infinity);
        {error, not_found} -> {error, sftp_not_found}
    end.

%% @doc RPC handler for sftp.mkdir
rpc_mkdir(#{<<"sftp_id">> := SftpId, <<"path">> := Path}) ->
    case find_by_sftp_id(SftpId) of
        {ok, Pid} -> gen_server:call(Pid, {mkdir, Path});
        {error, not_found} -> {error, sftp_not_found}
    end.

%% @doc RPC handler for sftp.remove
rpc_remove(#{<<"sftp_id">> := SftpId, <<"path">> := Path}) ->
    case find_by_sftp_id(SftpId) of
        {ok, Pid} -> gen_server:call(Pid, {remove, Path});
        {error, not_found} -> {error, sftp_not_found}
    end.

%% @doc RPC handler for sftp.stat
rpc_stat(#{<<"sftp_id">> := SftpId, <<"path">> := Path}) ->
    case find_by_sftp_id(SftpId) of
        {ok, Pid} -> gen_server:call(Pid, {stat, Path});
        {error, not_found} -> {error, sftp_not_found}
    end.

%% ---------- gen_server callbacks ----------

init([ConnId, SshRef]) ->
    Id = ssh_codec:gen_sftp_id(ConnId),
    case ssh_sftp:start_channel(SshRef, [{window, 10}, {packet, 32768}]) of
        {ok, SftpPid} ->
            {ok, #sftp{id = Id, conn_id = ConnId, ssh_ref = SshRef, sftp_pid = SftpPid}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(conn_id, _From, #sftp{conn_id = ConnId} = S) ->
    {reply, ConnId, S};

handle_call(get_id, _From, #sftp{id = Id} = S) ->
    {reply, Id, S};

handle_call({list_dir, Path}, _From, #sftp{sftp_pid = P} = S) ->
    case ssh_sftp:read_file_info_all(P, binary_to_list(Path)) of
        {ok, Entries} ->
            {reply, {ok, format_entries(Entries)}, S};
        {error, E} ->
            {reply, {error, E}, S}
    end;

handle_call({download, Remote, Local}, _From, #sftp{sftp_pid = P} = S) ->
    Result = do_download(P, binary_to_list(Remote), binary_to_list(Local), S),
    {reply, Result, S};

handle_call({upload, Local, Remote}, _From, #sftp{sftp_pid = P} = S) ->
    Result = do_upload(P, binary_to_list(Local), binary_to_list(Remote), S),
    {reply, Result, S};

handle_call({mkdir, Path}, _From, #sftp{sftp_pid = P} = S) ->
    Result = ssh_sftp:make_dir(P, binary_to_list(Path)),
    {reply, Result, S};

handle_call({remove, Path}, _From, #sftp{sftp_pid = P} = S) ->
    Result = ssh_sftp:delete(P, binary_to_list(Path)),
    {reply, Result, S};

handle_call({stat, Path}, _From, #sftp{sftp_pid = P} = S) ->
    case ssh_sftp:read_file_info(P, binary_to_list(Path)) of
        {ok, #file_info{size = Size, mtime = Mtime, mode = Mode, type = Type}} ->
            {reply, {ok, #{size => Size, mtime => Mtime, perms => Mode,
                           type => atom_to_binary(Type, utf8)}}, S};
        {error, E} ->
            {reply, {error, E}, S}
    end;

handle_call(_Req, _From, S) ->
    {reply, {error, not_implemented}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #sftp{sftp_pid = P}) when is_pid(P) ->
    _ = (catch ssh_sftp:stop_channel(P)),
    ok;
terminate(_Reason, _S) ->
    ok.

%% ---------- Internal ----------

%% @doc Format file_info entries for JSON response.
format_entries(Entries) ->
    [format_entry(E) || E <- Entries].

format_entry({Name, #file_info{size = Size, mtime = Mtime, mode = Mode, type = Type}}) ->
    #{
        name => Name,
        type => atom_to_binary(Type, utf8),
        size => Size,
        mtime => Mtime,
        perms => Mode
    }.

%% @doc Download a file from remote to local.
do_download(SftpPid, RemotePath, LocalPath, SftpState) ->
    case ssh_sftp:read_file_info(SftpPid, RemotePath) of
        {ok, #file_info{size = TotalSize, type = regular}} ->
            case file:open(LocalPath, [write, binary]) of
                {ok, LocalFile} ->
                    case ssh_sftp:open(SftpPid, RemotePath, [read, binary]) of
                        {ok, Handle} ->
                            Transferred = stream_download(SftpPid, Handle, LocalFile, 0, TotalSize, SftpState),
                            ssh_sftp:close(SftpPid, Handle),
                            file:close(LocalFile),
                            {ok, #{transferred => Transferred, total => TotalSize}};
                        {error, E} ->
                            file:close(LocalFile),
                            {error, E}
                    end;
                {error, E} ->
                    {error, E}
            end;
        {error, E} ->
            {error, E}
    end.

stream_download(SftpPid, Handle, LocalFile, Transferred, Total, SftpState) ->
    case ssh_sftp:read(SftpPid, Handle, 32768) of
        {ok, Data} ->
            ok = file:write(LocalFile, Data),
            NewTransferred = Transferred + byte_size(Data),
            push_progress(SftpState, NewTransferred, Total),
            case byte_size(Data) < 32768 of
                true -> NewTransferred;
                false -> stream_download(SftpPid, Handle, LocalFile, NewTransferred, Total, SftpState)
            end;
        eof ->
            Transferred
    end.

%% @doc Upload a file from local to remote.
do_upload(SftpPid, LocalPath, RemotePath, SftpState) ->
    case file:read_file_info(LocalPath) of
        {ok, #file_info{size = TotalSize}} ->
            case file:open(LocalPath, [read, binary]) of
                {ok, LocalFile} ->
                    case ssh_sftp:open(SftpPid, RemotePath, [write, binary]) of
                        {ok, Handle} ->
                            Transferred = stream_upload(SftpPid, Handle, LocalFile, 0, TotalSize, SftpState),
                            ssh_sftp:close(SftpPid, Handle),
                            file:close(LocalFile),
                            {ok, #{transferred => Transferred, total => TotalSize}};
                        {error, E} ->
                            file:close(LocalFile),
                            {error, E}
                    end;
                {error, E} ->
                    {error, E}
            end;
        {error, E} ->
            {error, E}
    end.

stream_upload(SftpPid, Handle, LocalFile, Transferred, Total, SftpState) ->
    case file:read(LocalFile, 32768) of
        {ok, Data} ->
            ok = ssh_sftp:write(SftpPid, Handle, Data),
            NewTransferred = Transferred + byte_size(Data),
            push_progress(SftpState, NewTransferred, Total),
            stream_upload(SftpPid, Handle, LocalFile, NewTransferred, Total, SftpState);
        eof ->
            Transferred
    end.

%% @doc Push a transfer progress notification to Ruby.
push_progress(#sftp{id = Id}, Transferred, Total) ->
    ssh_ipc_gateway:push_event(<<"sftp.progress">>, #{
        <<"sftp_id">> => Id,
        <<"transferred">> => Transferred,
        <<"total">> => Total,
        <<"speed">> => 0
    }).

%% @doc Find an SFTP session by sftp_id.
find_by_sftp_id(SftpId) ->
    case ets:lookup(sftp_index, SftpId) of
        [{_, Pid}] -> {ok, Pid};
        [] -> {error, not_found}
    end.


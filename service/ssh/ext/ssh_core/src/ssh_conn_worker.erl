-module(ssh_conn_worker).
-behaviour(gen_statem).

%% Connection worker — manages a single SSH connection's lifecycle + channels.
%% State machine: idle → connecting → authenticating → ready → reconnecting/closing → failed/closed
%%
%% Key design (LLD §6.3, E1/E2/E5 fixes):
%%   - OTP ssh integrates auth into ssh:connect/2,3
%%   - gen_statem (state_functions mode), not gen_fsm
%%   - Channels are spawned as children via proc_lib:spawn_link
%%   - Reconnect is NOT autonomous — Erlang notifies, Ruby decides

-export([
    start_link/1,
    do_connect/1,
    rpc_disconnect/1,
    rpc_channel_open/1,
    rpc_reconnect/1,
    get_state_name/1,
    get_state/1,
    get_ssh_ref/1,
    conn_id/1,
    build_ssh_options/1
]).
-export([callback_mode/0, init/1]).
-export([idle/3, connecting/3, authenticating/3, ready/3,
         reconnecting/3, closing/3, failed/3]).

-include("ssh_ipc.hrl").

%% ---------- Public API ----------

%% @doc Start a connection worker. Spec is the connect_spec map.
start_link(Spec) ->
    gen_statem:start_link(?MODULE, [Spec], []).

%% @doc Trigger the connection sequence.
%% Uses a generous gen_statem call timeout (connect_timeout + 10s buffer)
%% to avoid the call timing out before ssh:connect does.
do_connect(Pid) ->
    %% Get the spec's connect_timeout or default, add 10s buffer for state machine overhead
    case catch ssh_conn_worker:get_state(Pid) of
        #conn{spec = Spec} ->
            Timeout = maps:get(<<"connect_timeout_ms">>, Spec, ?CONNECT_TIMEOUT_MS),
            gen_statem:call(Pid, do_connect, Timeout + 10000);
        _ ->
            gen_statem:call(Pid, do_connect, ?CONNECT_TIMEOUT_MS + 10000)
    end.

%% @doc RPC handler for conn.disconnect
rpc_disconnect(#{<<"id">> := ConnId}) ->
    case find_by_conn_id(ConnId) of
        {ok, Pid} ->
            gen_statem:call(Pid, disconnect),
            #{ok => true};
        {error, not_found} ->
            {error, conn_not_found}
    end.

%% @doc RPC handler for conn.reconnect
rpc_reconnect(#{<<"id">> := ConnId}) ->
    case find_by_conn_id(ConnId) of
        {ok, Pid} ->
            gen_statem:call(Pid, reconnect);
        {error, not_found} ->
            {error, conn_not_found}
    end.

%% @doc RPC handler for channel.open
rpc_channel_open(#{<<"conn_id">> := ConnId} = Params) ->
    case find_by_conn_id(ConnId) of
        {ok, Pid} ->
            gen_statem:call(Pid, {open_channel, Params});
        {error, not_found} ->
            {error, conn_not_found}
    end.

%% @doc Get current state name (for conn.list).
get_state_name(Pid) ->
    gen_statem:call(Pid, get_state_name).

%% @doc Get full state record (internal use).
get_state(Pid) ->
    gen_statem:call(Pid, get_state).

%% @doc Get the OTP ssh connection reference.
get_ssh_ref(Pid) ->
    gen_statem:call(Pid, get_ssh_ref).

%% @doc Get conn_id for this worker.
conn_id(Pid) ->
    gen_statem:call(Pid, conn_id).

%% ---------- gen_statem callbacks ----------

callback_mode() -> state_functions.

init([Spec]) ->
    ConnId = ssh_codec:gen_conn_id(),
    Data = #conn{
        id = ConnId,
        spec = Spec,
        options = build_ssh_options(Spec)
    },
    {ok, idle, Data}.

%% ---------- State: idle ----------

idle({call, From}, do_connect, #conn{spec = Spec, id = Id} = D) ->
    {next_state, connecting, D, [{next_event, internal, {From, do_connect}}]};

idle({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, idle}]};

idle({call, From}, conn_id, #conn{id = Id}) ->
    {keep_state_and_data, [{reply, From, Id}]};

idle(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- State: connecting ----------

connecting(internal, {From, do_connect}, #conn{spec = Spec, id = Id, options = Opts} = D) ->
    Jumps = maps:get(<<"jumps">>, Spec, []),
    ConnectTimeout = maps:get(<<"connect_timeout_ms">>, Spec, ?CONNECT_TIMEOUT_MS),
    Result = case Jumps of
        [] ->
            Host = binary_to_list(maps:get(<<"host">>, Spec)),
            Port = maps:get(<<"port">>, Spec, 22),
            ssh:connect(Host, Port, Opts, ConnectTimeout);
        _ ->
            %% ProxyJump: jump chain handles the entire connection
            ssh_jump_chain:build(Spec, Jumps)
    end,
    case Result of
        {ok, SshRef} ->
            Fingerprint = get_host_fingerprint(SshRef),
            ssh_ipc_gateway:push_event(<<"conn.ready">>, #{
                <<"conn_id">> => Id,
                <<"fingerprint">> => Fingerprint
            }),
            {next_state, ready, D#conn{ssh_ref = SshRef},
             [{reply, From, {ok, #{conn_id => Id, fingerprint => Fingerprint}}}]};
        {error, Reason} ->
            ssh_ipc_gateway:push_event(<<"conn.failed">>, #{
                <<"conn_id">> => Id,
                <<"reason">> => atom_to_binary(Reason, utf8)
            }),
            {next_state, failed, D#conn{fail_reason = Reason},
             [{reply, From, {error, Reason}}]}
    end;

connecting({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, connecting}]};

connecting(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- State: authenticating ----------

%% OTP ssh does auth in ssh:connect. This state is a transient
%% placeholder for keyboard_interactive prompt handling.
authenticating({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, authenticating}]};

authenticating(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- State: ready ----------

ready({call, From}, {open_channel, Params}, #conn{ssh_ref = Ref, id = ConnId, next_ch_seq = Seq} = D) ->
    ChId = ssh_codec:gen_channel_id(ConnId),
    ChType = maps:get(<<"type">>, Params, <<"shell">>),
    Cols = maps:get(<<"cols">>, Params, 80),
    Rows = maps:get(<<"rows">>, Params, 24),
    TermType = maps:get(<<"term">>, Params, <<"xterm-256color">>),
    case ssh_channel_stm:start_link(ChId, ConnId, Ref, #{
        type => binary_to_atom(ChType, utf8),
        cols => Cols,
        rows => Rows,
        term_type => TermType,
        command => maps:get(<<"command">>, Params, undefined)
    }) of
        {ok, ChPid} ->
            %% Register in ETS index for channel lookup by id
            ets:insert(ch_index, {ChId, ChPid}),
            Channels = maps:put(ChId, ChPid, D#conn.channels),
            {keep_state, D#conn{channels = Channels, next_ch_seq = Seq + 1},
             [{reply, From, {ok, #{channel_id => ChId}}}]};
        {error, Reason} ->
            {keep_state_and_data, [{reply, From, {error, Reason}}]}
    end;

ready({call, From}, disconnect, #conn{ssh_ref = Ref} = D) ->
    ssh:close(Ref),
    {next_state, closing, D, [{reply, From, #{ok => true}}]};

ready({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, ready}]};

ready({call, From}, get_ssh_ref, #conn{ssh_ref = Ref}) ->
    {keep_state_and_data, [{reply, From, Ref}]};

ready({call, From}, get_state, D) ->
    {keep_state_and_data, [{reply, From, D}]};

ready({call, From}, conn_id, #conn{id = Id}) ->
    {keep_state_and_data, [{reply, From, Id}]};

ready(info, {ssh_channel_down, ChId}, #conn{channels = Chs} = D) ->
    ets:delete(ch_index, ChId),
    NewChs = maps:remove(ChId, Chs),
    {keep_state, D#conn{channels = NewChs}};

ready(info, {ssh_closed, _Reason}, #conn{id = Id} = D) ->
    ssh_ipc_gateway:push_event(<<"conn.closed">>, #{
        <<"conn_id">> => Id,
        <<"reason">> => <<"ssh_closed">>
    }),
    {next_state, failed, D#conn{ssh_ref = undefined}};

ready(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- State: reconnecting ----------

reconnecting({call, From}, reconnect, #conn{spec = Spec, id = Id, options = Opts} = D) ->
    Jumps = maps:get(<<"jumps">>, Spec, []),
    ConnectTimeout = maps:get(<<"connect_timeout_ms">>, Spec, ?CONNECT_TIMEOUT_MS),
    Result = case Jumps of
        [] ->
            Host = binary_to_list(maps:get(<<"host">>, Spec)),
            Port = maps:get(<<"port">>, Spec, 22),
            ssh:connect(Host, Port, Opts, ConnectTimeout);
        _ ->
            ssh_jump_chain:build(Spec, Jumps)
    end,
    case Result of
        {ok, SshRef} ->
            ssh_ipc_gateway:push_event(<<"conn.ready">>, #{<<"conn_id">> => Id}),
            {next_state, ready, D#conn{ssh_ref = SshRef, reconnect_count = 0},
             [{reply, From, {ok, #{conn_id => Id}}}]};
        {error, Reason} ->
            {keep_state, D#conn{reconnect_count = D#conn.reconnect_count + 1},
             [{reply, From, {error, Reason}}]}
    end;

reconnecting({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, reconnecting}]};

reconnecting(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- State: closing ----------

closing({call, From}, _Msg, _D) ->
    {keep_state_and_data, [{reply, From, {error, closing}}]};

closing(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- State: failed ----------

failed({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, failed}]};

failed({call, From}, conn_id, #conn{id = Id}) ->
    {keep_state_and_data, [{reply, From, Id}]};

failed({call, From}, reconnect, D) ->
    {next_state, reconnecting, D, [{next_event, internal, {From, reconnect}}]};

failed(Type, Msg, D) ->
    handle_common(Type, Msg, D).

%% ---------- Common handler ----------

handle_common({call, From}, get_state_name, _D) ->
    {keep_state_and_data, [{reply, From, unknown}]};

handle_common({call, From}, conn_id, #conn{id = Id}) ->
    {keep_state_and_data, [{reply, From, Id}]};

handle_common(_Type, _Msg, D) ->
    {keep_state, D}.

%% ---------- Internal: SSH options ----------

%% @doc Build ssh:connect options from the connect spec.
build_ssh_options(Spec) ->
    ConnectTimeout = maps:get(<<"connect_timeout_ms">>, Spec, ?CONNECT_TIMEOUT_MS),
    Auth = maps:get(<<"auth">>, Spec, #{}),
    [
        {user, binary_to_list(maps:get(<<"user">>, Spec))},
        {silently_accept_hosts, false},
        {key_cb, {ssh_auth_engine, [{auth_map, Auth}]}},
        {user_dir, binary_to_list(maps:get(<<"key_dir">>, Spec, <<".">>))},
        {preferred_algorithms, build_algorithms(maps:get(<<"algorithms">>, Spec, undefined))},
        {connect_timeout, ConnectTimeout},
        {user_interaction, false}
    ]
    ++ build_auth_options(maps:get(<<"auth">>, Spec, #{}))
    ++ build_proxy_options(maps:get(<<"proxy">>, Spec, undefined))
    ++ build_jump_options(maps:get(<<"jumps">>, Spec, [])).

%% @doc Build preferred_algorithms option.
%% Returns a keyword list (not a map) for OTP 17 compatibility.
%% OTP 17 expects cipher and mac as [{client2server,[...]}, {server2client,[...]}] pairs,
%% while kex and public_key use flat lists.
%%
%% If user provides custom algorithms in spec, merge them with defaults:
%%   - User-specified algorithms are prepended (higher priority)
%%   - Default algorithms fill in any categories not specified
%%   - Within a category, user list takes priority, defaults appended for fallback
%% If no custom algorithms, use defaults.
-spec build_algorithms(undefined | map()) -> [{atom(), term()}].
build_algorithms(undefined) ->
    preferred_algs();
build_algorithms(UserAlgs) when is_map(UserAlgs) ->
    Defaults = preferred_algs(),
    %% Convert Defaults to a map for easy merging
    DefaultMap = #{
        kex => proplists:get_value(kex, Defaults),
        public_key => proplists:get_value(public_key, Defaults),
        cipher => proplists:get_value(cipher, Defaults),
        mac => proplists:get_value(mac, Defaults)
    },
    %% Merge each category: user first, then defaults not already included
    MergedMap = maps:map(fun(Category, DefaultList) ->
        UserList = case maps:get(Category, UserAlgs, undefined) of
            undefined -> [];
            L when is_list(L) -> [normalize_alg(A) || A <- L];
            _ -> []
        end,
        UserList ++ [A || A <- DefaultList, not lists:member(A, UserList)]
    end, DefaultMap),
    %% Convert back to keyword list format
    [
        {kex, maps:get(kex, MergedMap)},
        {public_key, maps:get(public_key, MergedMap)},
        {cipher, maps:get(cipher, MergedMap)},
        {mac, maps:get(mac, MergedMap)}
    ].

%% @doc Normalize algorithm atom from binary or atom.
normalize_alg(Bin) when is_binary(Bin) ->
    try binary_to_existing_atom(Bin, utf8) catch _:_ -> binary_to_atom(Bin, utf8) end;
normalize_alg(Atom) when is_atom(Atom) ->
    Atom.

%% @doc Preferred algorithms — meets FR-CONN-001 quantitative targets.
%% Returns keyword list format for OTP 17 compatibility:
%%   kex, public_key => flat list
%%   cipher, mac => [{client2server,[...]}, {server2client,[...]}] pairs
preferred_algs() ->
    Ciphers = ['aes256-gcm@openssh.com',
               'aes128-gcm@openssh.com',
               'chacha20-poly1305@openssh.com',
               'aes256-ctr', 'aes192-ctr', 'aes128-ctr'],
    Macs = ['hmac-sha2-256',
            'hmac-sha2-512',
            'hmac-sha2-256-etm@openssh.com',
            'hmac-sha2-512-etm@openssh.com'],
    [
        {kex, ['curve25519-sha256@libssh.org',
               'curve25519-sha256',
               'ecdh-sha2-nistp256',
               'ecdh-sha2-nistp384',
               'ecdh-sha2-nistp521',
               'diffie-hellman-group16-sha512',
               'diffie-hellman-group14-sha256']},
        {public_key, ['ssh-ed25519',
                      'rsa-sha2-512',
                      'rsa-sha2-256',
                      'ecdsa-sha2-nistp256',
                      'ecdsa-sha2-nistp384',
                      'ecdsa-sha2-nistp521']},
        {cipher, [{client2server, Ciphers}, {server2client, Ciphers}]},
        {mac, [{client2server, Macs}, {server2client, Macs}]}
    ].

%% @doc Build auth options from the auth map.
build_auth_options(#{<<"type">> := <<"password">>} = Auth) ->
    [{password, binary_to_list(maps:get(<<"password">>, Auth))}];
build_auth_options(#{<<"type">> := <<"publickey">>}) ->
    %% Key loading handled by ssh_auth_engine key_cb callbacks
    [];
build_auth_options(#{<<"type">> := <<"keyboard_interactive">>} = Auth) ->
    [{keyboard_interactive, fun(_Prompts, _Ssh) -> handle_kbi_prompts(Auth) end}];
build_auth_options(_) ->
    [].

%% @doc Handle keyboard-interactive prompts.
handle_kbi_prompts(Auth) ->
    %% Return responses from auth map
    Responses = maps:get(<<"responses">>, Auth, []),
    {ok, [binary_to_list(R) || R <- Responses]}.

%% @doc Build proxy options (SOCKS5/HTTP).
build_proxy_options(undefined) -> [];
build_proxy_options(#{<<"type">> := _, <<"host">> := _, <<"port">> := _} = Proxy) ->
    [{sock_fun, make_proxy_sock_fun(Proxy)}].

%% @doc Build jump chain options.
%% Jumps are not handled as ssh options — they require a separate connection
%% sequence via ssh_jump_chain:build/2, called from connecting/reconnecting states.
%% Returns [] so build_ssh_options skips them.
build_jump_options(_Jumps) -> [].

%% @doc Make proxy sock_fun — supports SOCKS5 and HTTP CONNECT.
%% The returned fun must implement the OTP ssh sock_fun contract:
%%   (connect, Host, Port, Timeout)  -> {ok, Sock} | {error, _}
%%   (close,   Sock,  _,     _)      -> ok
%%   (send,    Sock,  Data,  _)      -> ok | {error,_}
%%   (recv,    Sock,  Len,   Timeout) -> {ok, Data} | {error,_}
make_proxy_sock_fun(Proxy) ->
    ProxyHost = binary_to_list(maps:get(<<"host">>, Proxy)),
    ProxyPort = maps:get(<<"port">>, Proxy),
    ProxyType = binary_to_list(maps:get(<<"type">>, Proxy, <<"socks5">>)),
    Username = case maps:get(<<"username">>, Proxy, undefined) of
        undefined -> undefined;
        UBin -> UBin
    end,
    Password = case maps:get(<<"password">>, Proxy, undefined) of
        undefined -> undefined;
        PBin -> PBin
    end,
    fun
        (connect, TargetHost, TargetPort, Timeout) ->
            case gen_tcp:connect(ProxyHost, ProxyPort, [binary, {active, false}, {packet, raw}], Timeout) of
                {error, _} = E -> E;
                {ok, Sock} ->
                    case do_proxy_handshake(Sock, ProxyType, TargetHost, TargetPort, Username, Password, Timeout) of
                        ok ->
                            %% Switch to active mode for async recv
                            inet:setopts(Sock, [{active, true}]),
                            {ok, {proxy_sock, Sock}};
                        {error, _Reason} ->
                            gen_tcp:close(Sock),
                            {error, proxy_handshake_failed}
                    end
            end;
        (close, {proxy_sock, Sock}, _A3, _A4) ->
            gen_tcp:close(Sock),
            ok;
        (send, {proxy_sock, Sock}, Data, _A4) ->
            gen_tcp:send(Sock, Data);
        (recv, {proxy_sock, Sock}, _Len, _Timeout) ->
            receive
                {tcp, Sock, Data} -> {ok, Data};
                {tcp_closed, Sock} -> {error, closed};
                {tcp_error, Sock, _} -> {error, tcp_error}
            after ?CONNECT_TIMEOUT_MS -> {error, timeout}
            end
    end.

%% @doc SOCKS5 handshake — RFC 1928/1929
do_proxy_handshake(Sock, "socks5", TargetHost, TargetPort, Username, Password, Timeout) ->
    %% Step 1: greeting
    AuthMethod = case {Username, Password} of
        {undefined, _} -> 0;  % no auth
        _ -> 2                % username/password
    end,
    ok = gen_tcp:send(Sock, <<5, 1, AuthMethod>>),
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, <<5, 0>>} when AuthMethod =:= 0 -> ok;  % no auth needed
        {ok, <<5, 2>>} when AuthMethod =:= 2 ->
            %% Step 2: username/password auth (RFC 1929)
            ULen = byte_size(Username),
            PLen = byte_size(Password),
            ok = gen_tcp:send(Sock, <<1, ULen, Username/binary, PLen, Password/binary>>),
            case gen_tcp:recv(Sock, 0, Timeout) of
                {ok, <<1, 0>>} -> ok;
                _ -> {error, socks5_auth_failed}
            end;
        _ ->
            {error, socks5_greeting_failed}
    end,
    %% Step 3: connect request
    TargetHostBin = list_to_binary(TargetHost),
    HostBytes = case inet:parse_address(TargetHost) of
        {ok, {A, B, C, D}} -> <<1, A:8, B:8, C:8, D:8>>;
        _ -> <<3, (byte_size(TargetHostBin)):8, TargetHostBin/binary>>
    end,
    ok = gen_tcp:send(Sock, <<5, 1, 0, HostBytes/binary, TargetPort:16>>),
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, <<5, 0, _Rest/binary>>} -> ok;
        {ok, <<5, ReplyCode, _Rest/binary>>} -> {error, {socks5_connect_rejected, ReplyCode}};
        _ -> {error, socks5_connect_failed}
    end;

%% @doc HTTP CONNECT handshake — RFC 7231
do_proxy_handshake(Sock, "http", TargetHost, TargetPort, Username, Password, Timeout) ->
    ConnectLine = io_lib:format("CONNECT ~s:~p HTTP/1.1\r\nHost: ~s:~p\r\n",
                                [TargetHost, TargetPort, TargetHost, TargetPort]),
    AuthHeader = case {Username, Password} of
        {undefined, _} -> "";
        _ ->
            Creds = base64:encode(<<Username/binary, ":", Password/binary>>),
            io_lib:format("Proxy-Authorization: Basic ~s\r\n", [Creds])
    end,
    Request = iolist_to_binary([ConnectLine, AuthHeader, "\r\n"]),
    ok = gen_tcp:send(Sock, Request),
    case gen_tcp:recv(Sock, 0, Timeout) of
        {ok, Data} ->
            case binary:match(Data, <<"200">>) of
                nomatch -> {error, http_connect_failed};
                _ -> ok
            end;
        _ -> {error, http_connect_timeout}
    end;

do_proxy_handshake(_Sock, Unknown, _Host, _Port, _User, _Pass, _Timeout) ->
    {error, {unsupported_proxy_type, Unknown}}.

%% ---------- Internal: Helpers ----------

%% @doc Get host fingerprint from a connected ssh_ref.
%% Extracts the peer public key and computes SHA-256 fingerprint.
get_host_fingerprint(SshRef) ->
    case ssh_connection:hostkey(SshRef) of
        {ok, Key} ->
            ssh_codec:fingerprint(Key);
        {error, _} ->
            <<"SHA256:unknown">>
    end.

%% @doc Find a worker by conn_id (scans conn_sup children).
find_by_conn_id(ConnId) ->
    Match = [Pid || Pid <- ssh_conn_sup:all_workers(),
                    conn_id(Pid) =:= ConnId],
    case Match of
        [Pid | _] -> {ok, Pid};
        [] -> {error, not_found}
    end.

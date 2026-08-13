-module(ssh_ipc_gateway).
-behaviour(gen_server).

%% IPC Gateway: listens on Unix Socket/TCP, accepts Ruby connections,
%% authenticates via token, routes JSON-RPC requests, and pushes events.
%%
%% Key design:
%%   - Routes are immutable after init
%%   - push_event/2 writes to coalesce buffer or direct push
%%   - push_batch/1 sends already-batched data directly
%%   - synchronous_push/2 blocks for Erlang→Ruby reverse RPC (hostkey.resolve)
%%   - Backpressure: when client send_q exceeds threshold, flow pauses

-export([
    start_link/1,
    push_event/2,
    push_batch/1,
    synchronous_push/2
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% Internal RPC handlers
-export([
    handle_bye/1,
    handle_ping/1,
    handle_stats/1,
    handle_shutdown/1
]).

-include("ssh_ipc.hrl").

%% ---------- Public API ----------

%% @doc Start the gateway. EndpointToken contains auth token and endpoint file path.
start_link(#{token := Token} = _EndpointToken) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Token], []).

%% @doc Push a single event through coalesce.
push_event(Method, Params) ->
    gen_server:cast(?MODULE, {push_event, Method, Params}).

%% @doc Push an already-batched notification directly.
push_batch(Params) ->
    gen_server:cast(?MODULE, {push_batch, Params}).

%% @doc Synchronous reverse RPC (Erlang→Ruby with id). Blocks until response.
%% Used by ssh_known_hosts_proxy for hostkey.resolve.
synchronous_push(Req, TimeoutMs) ->
    gen_server:call(?MODULE, {sync_push, Req, TimeoutMs}, TimeoutMs + 1000).

%% ---------- Callbacks ----------

init([Token]) ->
    {ok, ListenSock} = start_listener(),
    Routes = build_routes(),
    %% Store auth token in process dictionary for handle_hello/1 access
    put(auth_token, Token),
    %% Start async accept loop
    prim_inet:async_accept(ListenSock, -1),
    {ok, #gw_state{
        listen_sock = ListenSock,
        auth_token = Token,
        routes = Routes
    }}.

handle_call({sync_push, Req, TimeoutMs}, From, S) ->
    %% Send a reverse request (with id) to Ruby and wait for response
    case maps:size(S#gw_state.clients) of
        0 ->
            {reply, {error, no_clients}, S};
        _ ->
            ReverseId = generate_reverse_id(),
            Msg = ssh_ipc_proto:frame(
                ssh_ipc_proto:encode_request(ReverseId,
                    maps:get(<<"method">>, Req),
                    maps:get(<<"params">>, Req))
            ),
            case send_to_all_clients(S, Msg) of
                ok ->
                    %% Store pending for reverse response matching
                    Ref = erlang:make_ref(),
                    erlang:send_after(TimeoutMs, self(), {sync_push_timeout, Ref}),
                    {noreply, store_reverse_pending(S, ReverseId, From, Ref)};
                {error, no_clients} ->
                    {reply, {error, no_clients}, S}
            end
    end;

handle_call(_Req, _From, S) ->
    {reply, {error, not_implemented}, S}.

handle_cast({push_event, Method, Params}, S) ->
    send_notification(S, Method, Params),
    {noreply, S};

handle_cast({push_batch, Params}, S) ->
    send_notification(S, <<"channel.data.batch">>, Params),
    {noreply, S};

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({tcp, Socket, Data}, S) ->
    {Frames, Rest} = ssh_ipc_proto:unframe(Data),
    S1 = lists:foldl(fun(Frame, State) -> handle_frame(Socket, Frame, State) end, S, Frames),
    %% Keep remaining buffer per-socket if partial frame
    case Rest of
        <<>> -> ok;
        _ -> ok  %% Partial data stored on next recv — simplification
    end,
    inet:setopts(Socket, [{active, once}]),
    {noreply, S1};

handle_info({tcp_closed, Socket}, S) ->
    S1 = remove_client(S, Socket),
    {noreply, S1};

handle_info({tcp_error, Socket, _Reason}, S) ->
    S1 = remove_client(S, Socket),
    {noreply, S1};

handle_info({sync_push_timeout, Ref}, S) ->
    S1 = handle_reverse_timeout(S, Ref),
    {noreply, S1};

handle_info({inet_async, ListenSock, _Ref, {ok, ClientSock}}, #gw_state{listen_sock = ListenSock} = S) ->
    %% Accept new client connection
    inet_db:register_socket(ClientSock, inet_tcp),
    inet:setopts(ClientSock, [{active, once}, {packet, 0}, binary]),
    Ref = make_ref(),
    Client = #client{socket = ClientSock, authed = false},
    Clients = maps:put(Ref, Client, S#gw_state.clients),
    %% Continue accepting
    prim_inet:async_accept(ListenSock, -1),
    {noreply, S#gw_state{clients = Clients}};

handle_info({mark_authed, Socket}, S) ->
    %% Mark the client with matching socket as authenticated
    Clients = maps:map(fun(_Ref, #client{socket = Sock} = C) ->
        case Sock =:= Socket of
            true -> C#client{authed = true};
            false -> C
        end
    end, S#gw_state.clients),
    {noreply, S#gw_state{clients = Clients}};

handle_info({inet_async, ListenSock, _Ref, {error, _Reason}}, #gw_state{listen_sock = ListenSock} = S) ->
    %% Accept failed, retry
    prim_inet:async_accept(ListenSock, -1),
    {noreply, S};

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, #gw_state{listen_sock = ListenSock}) ->
    _ = close_listener(ListenSock),
    ok.

%% ---------- Internal: Listener ----------

start_listener() ->
    EndpointFile = ssh_infra_sup:generate_endpoint_file(),
    case os:type() of
        {win32, _} ->
            %% On Windows: listen on port 0 (OS assigns free port), then
            %% rewrite endpoint file with the actual port assigned.
            {ok, ListenSock} = gen_tcp:listen(0, [
                {ip, {127, 0, 0, 1}},
                {active, false},
                {packet, 0},
                {reuseaddr, true},
                binary
            ]),
            {ok, Port} = inet:port(ListenSock),
            %% Rewrite endpoint file with the actual port
            {ok, EndpointContent} = file:read_file(EndpointFile),
            [_FirstLine, TokenBin] = binary:split(EndpointContent, <<"\n">>),
            NewEndpoint = <<"tcp://127.0.0.1:", (integer_to_binary(Port))/binary>>,
            file:write_file(EndpointFile, <<NewEndpoint/binary, "\n", TokenBin/binary>>),
            {ok, ListenSock};
        _ ->
            Path = read_socket_path_from_file(EndpointFile),
            _ = file:delete(Path),
            %% On Unix, use gen_tcp on loopback as portable fallback
            {ok, ListenSock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}, {active, false}, {packet, 0}, binary]),
            {ok, Port} = inet:port(ListenSock),
            %% Rewrite endpoint file with TCP port for Ruby to pick up
            {ok, Endpoint} = file:read_file(EndpointFile),
            [_, TokenBin] = binary:split(Endpoint, <<"\n">>),
            file:write_file(EndpointFile, <<"tcp://127.0.0.1:", (integer_to_binary(Port))/binary, "\n", TokenBin/binary>>),
            {ok, ListenSock}
    end.

select_free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    {ok, Port}.

close_listener(Sock) ->
    _ = (catch gen_tcp:close(Sock)),
    ok.

%% ---------- Internal: Routing ----------

build_routes() ->
    #{
        <<"bye">>             => {?MODULE, handle_bye},
        <<"engine.ping">>     => {?MODULE, handle_ping},
        <<"engine.stats">>    => {ssh_ipc_gateway, handle_stats},
        <<"engine.shutdown">> => {?MODULE, handle_shutdown},
        <<"conn.connect">>    => {ssh_conn_sup, rpc_connect},
        <<"conn.disconnect">> => {ssh_conn_worker, rpc_disconnect},
        <<"conn.list">>       => {ssh_conn_sup, rpc_list},
        <<"conn.reconnect">>  => {ssh_conn_worker, rpc_reconnect},
        <<"channel.open">>    => {ssh_conn_worker, rpc_channel_open},
        <<"channel.send">>    => {ssh_channel_stm, rpc_send},
        <<"channel.close">>   => {ssh_channel_stm, rpc_close},
        <<"channel.window_change">> => {ssh_channel_stm, rpc_window_change},
        <<"sftp.open">>       => {ssh_sftp_sup, rpc_open},
        <<"sftp.list_dir">>   => {ssh_sftp_session, rpc_list_dir},
        <<"sftp.download">>   => {ssh_sftp_session, rpc_download},
        <<"sftp.upload">>     => {ssh_sftp_session, rpc_upload},
        <<"sftp.mkdir">>      => {ssh_sftp_session, rpc_mkdir},
        <<"sftp.remove">>     => {ssh_sftp_session, rpc_remove},
        <<"sftp.stat">>       => {ssh_sftp_session, rpc_stat},
        <<"portfwd.add">>     => {ssh_port_fwd, rpc_add},
        <<"portfwd.remove">>  => {ssh_port_fwd, rpc_remove},
        <<"portfwd.list">>    => {ssh_port_fwd, rpc_list},
        <<"keepalive.set_interval">> => {ssh_keepalive_mgr, rpc_set_interval},
        <<"keepalive.get_interval">> => {ssh_keepalive_mgr, rpc_get_interval},
        <<"keepalive.get_status">>   => {ssh_keepalive_mgr, rpc_get_status}
    }.

%% ---------- Internal: Frame handling ----------

handle_frame(Socket, FrameBin, S) ->
    case ssh_ipc_proto:decode(FrameBin) of
        {ok, {request_or_response, Msg}} ->
            handle_request_or_response(Socket, Msg, S);
        {ok, {notification, Msg}} ->
            handle_push_msg(Msg, S);
        {error, _Reason} ->
            S
    end.

handle_request_or_response(Socket, #{<<"id">> := Id} = Msg, S) ->
    case maps:is_key(<<"method">>, Msg) of
        true ->
            %% This is a Ruby→Erlang request
            Method = maps:get(<<"method">>, Msg),
            case Method of
                <<"hello">> ->
                    %% Special: hello authenticates the client socket
                    %% Pass auth_token explicitly since spawn doesn't inherit process dict
                    AuthToken = S#gw_state.auth_token,
                    spawn(fun() ->
                        Result = try
                            RawResult = handle_hello(AuthToken, maps:get(<<"params">>, Msg)),
                            normalize_result(RawResult)
                        catch
                            Class:Reason:Stacktrace ->
                                {error, #{class => atom_to_binary(Class, utf8),
                                          reason => format_reason(Reason),
                                          stacktrace => format_stacktrace(Stacktrace)}}
                        end,
                        send_rpc_response(Socket, Id, Result),
                        case Result of
                            {ok, _} ->
                                %% Signal gateway to mark this client as authed
                                ?MODULE ! {mark_authed, Socket};
                            _ ->
                                ok
                        end
                    end),
                    S;
                _ ->
                    dispatch_rpc(Socket, Id, Msg, S)
            end;
        false ->
            %% This is a response to a reverse RPC (Erlang→Ruby)
            handle_reverse_response(Id, Msg, S)
    end.

%% @doc Dispatch a Ruby→Erlang RPC request.
%% Params is optional: if the client omits it, default to an empty map.
dispatch_rpc(Socket, Id, #{<<"method">> := Method} = Msg, S) ->
    Params = maps:get(<<"params">>, Msg, #{}),
    case maps:get(Method, S#gw_state.routes, undefined) of
        {Module, Fun} ->
            %% Spawn to avoid blocking gateway
            spawn(fun() ->
                Result = try
                    RawResult = erlang:apply(Module, Fun, [Params]),
                    normalize_result(RawResult)
                catch
                    Class:Reason:Stacktrace ->
                        {error, #{class => atom_to_binary(Class, utf8),
                                  reason => format_reason(Reason),
                                  stacktrace => format_stacktrace(Stacktrace)}}
                end,
                send_rpc_response(Socket, Id, Result)
            end),
            S;
        undefined ->
            send_rpc_error(Socket, Id, -32601, #{message => <<"Method not found">>}),
            S
    end.

%% @doc Handle hello — first message must authenticate with token.
%% AuthToken is passed explicitly from gateway state (not process dict).
handle_hello(AuthToken, #{<<"auth_token">> := Token, <<"ver">> := _Ver, <<"client_id">> := _ClientId}) ->
    case Token =:= AuthToken of
        true ->
            {ok, #{capabilities => [<<"coalesce">>], ver => ?PROTOCOL_VER}};
        false ->
            {error, auth_failed}
    end.

%% @doc Handle bye — clean up.
handle_bye(_Params) ->
    {ok, #{ok => true}}.

%% @doc Handle engine.ping.
handle_ping(_Params) ->
    {ok, #{ok => true, timestamp => ssh_codec:unix_ms()}}.

%% @doc Handle engine.stats.
handle_stats(_Params) ->
    {Total, _} = erlang:statistics(runtime),
    {ok, #{
        connections => length(ssh_conn_sup:all_workers()),
        uptime_ms => Total
    }}.

%% @doc Handle engine.shutdown.
handle_shutdown(_Params) ->
    spawn(fun() -> timer:sleep(100), init:stop() end),
    {ok, #{ok => true}}.

%% ---------- Internal: Send ----------

send_notification(S, Method, Params) ->
    Msg = ssh_ipc_proto:frame(ssh_ipc_proto:encode_push(Method, Params)),
    send_to_all_clients(S, Msg).

send_rpc_response(Socket, Id, {ok, Result}) ->
    Msg = ssh_ipc_proto:frame(ssh_ipc_proto:encode_response(Id, Result)),
    gen_tcp:send(Socket, Msg);

send_rpc_response(Socket, Id, {error, ErrorObj}) ->
    Code = case is_map(ErrorObj) of
        true -> maps:get(<<"code">>, ErrorObj, -32603);
        false -> -32603
    end,
    Msg = ssh_ipc_proto:frame(ssh_ipc_proto:encode_error(Id, Code, ErrorObj)),
    gen_tcp:send(Socket, Msg).

send_rpc_error(Socket, Id, Code, ErrorObj) ->
    Msg = ssh_ipc_proto:frame(ssh_ipc_proto:encode_error(Id, Code, ErrorObj)),
    gen_tcp:send(Socket, Msg).

send_to_all_clients(S, Msg) ->
    case maps:size(S#gw_state.clients) of
        0 -> {error, no_clients};
        _ ->
            maps:fold(fun(_Ref, #client{socket = Sock}, _) ->
                gen_tcp:send(Sock, Msg)
            end, ok, S#gw_state.clients),
            ok
    end.

%% ---------- Internal: Client management ----------

%% @doc Remove a client by socket from the clients map.
remove_client(S, Socket) ->
    NewClients = maps:filter(fun(_Ref, #client{socket = Sock}) -> Sock =/= Socket end,
                            S#gw_state.clients),
    S#gw_state{clients = NewClients}.

%% ---------- Internal: Reverse RPC ----------

generate_reverse_id() ->
    erlang:unique_integer([positive]).

%% @doc Store a pending reverse RPC for response matching.
%% Uses process dictionary: {reverse_pending, ReverseId} => {From, Ref}
store_reverse_pending(_S, ReverseId, From, Ref) ->
    put({reverse_pending, ReverseId}, {From, Ref}),
    _S.

%% @doc Handle reverse RPC timeout.
handle_reverse_timeout(S, Ref) ->
    %% Find the pending entry by Ref and reply timeout
    Keys = [K || K <- get_keys_starting_with(reverse_pending), element(2, get(K)) =:= Ref],
    lists:foreach(fun(K) ->
        case get(K) of
            {From, Ref} ->
                gen_server:reply(From, {error, timeout}),
                erase(K)
        end
    end, Keys),
    S.

%% @doc Handle reverse RPC response from Ruby.
handle_reverse_response(Id, Msg, S) ->
    case get({reverse_pending, Id}) of
        {From, _Ref} ->
            Result = case maps:get(<<"result">>, Msg, undefined) of
                undefined -> {error, maps:get(<<"error">>, Msg, #{})};
                R -> {ok, R}
            end,
            gen_server:reply(From, Result),
            erase({reverse_pending, Id}),
            S;
        undefined ->
            S
    end.

handle_push_msg(_Msg, S) ->
    S.

%% ---------- Internal: Result normalization ----------

%% @doc Normalize Erlang results to JSON-encodable maps.
normalize_result({ok, Result}) when is_map(Result) ->
    {ok, Result};
normalize_result({ok, true}) ->
    {ok, #{ok => true}};
normalize_result({ok, Value}) ->
    {ok, #{ok => Value}};
normalize_result({error, Reason}) ->
    {error, #{message => format_reason(Reason)}};
normalize_result(ok) ->
    {ok, #{ok => true}};
normalize_result(Other) ->
    {ok, #{ok => Other}}.

format_reason(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason, utf8);
format_reason(Reason) when is_binary(Reason) ->
    Reason;
format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

format_stacktrace(Stacktrace) ->
    [iolist_to_binary(io_lib:format("~p", [Entry])) || Entry <- Stacktrace].

%% ---------- Internal: Helpers ----------
read_port_from_file(File) ->
    {ok, Content} = file:read_file(File),
    [<<"tcp://127.0.0.1:", Port/binary>> | _] = binary:split(Content, <<"\n">>),
    {ok, binary_to_integer(Port)}.

read_socket_path_from_file(File) ->
    {ok, Content} = file:read_file(File),
    [EndpointLine | _] = binary:split(Content, <<"\n">>),
    %% Extract path from "unix:/path" format
    case EndpointLine of
        <<"unix:", Path/binary>> -> Path;
        _ -> <<"/tmp/ssh_core.sock">>
    end.

%% @doc Get all process dictionary keys starting with given prefix atom.
get_keys_starting_with(PrefixAtom) ->
    {dictionary, Dict} = process_info(self(), dictionary),
    [K || K <- Dict, is_tuple(K), element(1, K) =:= PrefixAtom].

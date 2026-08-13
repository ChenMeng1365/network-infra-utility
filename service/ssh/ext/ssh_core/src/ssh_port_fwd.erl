-module(ssh_port_fwd).
-behaviour(gen_server).

%% Port forwarding manager — manages local/remote/dynamic port forward rules.
%%
%% Key design (LLD §6.8, E4 fix):
%%   - Local forward: gen_tcp:listen + ssh_connection:direct_tcpip
%%   - Remote forward: ssh_connection:tcpip_forward/3
%%   - Dynamic (SOCKS5): Local forward + self-implemented SOCKS5 negotiation (V2.0)
%%
%% One gen_server per connection, manages all rules for that connection.

-export([
    start_link/1,
    rpc_add/1,
    rpc_remove/1,
    rpc_list/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("ssh_ipc.hrl").

-record(fwd_rule, {
    id :: binary(),
    type :: local | remote | dynamic,
    local_port :: pos_integer(),
    remote_host :: binary() | undefined,
    remote_port :: pos_integer() | undefined,
    enabled = true :: boolean(),
    listener_pid :: pid() | undefined
}).

-record(st, {
    conn_id :: binary(),
    ssh_ref :: reference(),
    rules = #{} :: #{binary() => #fwd_rule{}},
    next_seq = 1 :: pos_integer()
}).

%% ---------- Public API ----------

%% @doc Start a port forwarding manager for a connection.
start_link(#{conn_id := ConnId, ssh_ref := SshRef}) ->
    gen_server:start_link(?MODULE, [ConnId, SshRef], []).

%% @doc RPC handler for portfwd.add
rpc_add(#{<<"conn_id">> := ConnId, <<"type">> := TypeBin,
          <<"local_port">> := LocalPort} = Params) ->
    case find_mgr(ConnId) of
        {ok, Pid} ->
            gen_server:call(Pid, {add, #{
                type => binary_to_atom(TypeBin, utf8),
                local_port => LocalPort,
                remote_host => maps:get(<<"remote_host">>, Params, undefined),
                remote_port => maps:get(<<"remote_port">>, Params, undefined)
            }});
        {error, not_found} ->
            {error, conn_not_found}
    end.

%% @doc RPC handler for portfwd.list
rpc_list(#{<<"conn_id">> := ConnId}) ->
    case find_mgr(ConnId) of
        {ok, Pid} ->
            gen_server:call(Pid, list);
        {error, not_found} ->
            %% No forwarding manager started for this connection yet
            {ok, []}
    end.

%% @doc RPC handler for portfwd.remove
rpc_remove(#{<<"conn_id">> := ConnId, <<"rule_id">> := RuleId}) ->
    case find_mgr(ConnId) of
        {ok, Pid} ->
            gen_server:call(Pid, {remove, RuleId});
        {error, not_found} ->
            {error, conn_not_found}
    end.

%% ---------- gen_server callbacks ----------

init([ConnId, SshRef]) ->
    {ok, #st{conn_id = ConnId, ssh_ref = SshRef}}.

handle_call({add, #{type := local, local_port := LocalPort,
                    remote_host := RHost, remote_port := RPort}}, _From, S) ->
    RuleId = gen_rule_id(S),
    Rule = #fwd_rule{id = RuleId, type = local, local_port = LocalPort,
                     remote_host = RHost, remote_port = RPort},
    case start_local_listener(S#st.ssh_ref, Rule) of
        {ok, ListenerPid} ->
            Rule1 = Rule#fwd_rule{listener_pid = ListenerPid},
            Rules = maps:put(RuleId, Rule1, S#st.rules),
            {reply, {ok, #{rule_id => RuleId}}, S#st{rules = Rules, next_seq = S#st.next_seq + 1}};
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;

handle_call({add, #{type := remote, local_port := RemotePort,
                    remote_host := LHost, remote_port := LPort}}, _From, S) ->
    RuleId = gen_rule_id(S),
    case ssh_connection:tcpip_forward(S#st.ssh_ref,
            binary_to_list(LHost), LPort, RemotePort) of
        ok ->
            Rule = #fwd_rule{id = RuleId, type = remote, local_port = RemotePort,
                             remote_host = LHost, remote_port = LPort},
            Rules = maps:put(RuleId, Rule, S#st.rules),
            {reply, {ok, #{rule_id => RuleId}}, S#st{rules = Rules, next_seq = S#st.next_seq + 1}};
        {error, Reason} ->
            {reply, {error, Reason}, S}
    end;

handle_call({add, #{type := dynamic, local_port := LocalPort}}, _From, S) ->
    %% SOCKS5 dynamic forward — V2.0
    {reply, {error, not_implemented_v1}, S};

handle_call({remove, RuleId}, _From, S) ->
    case maps:get(RuleId, S#st.rules, undefined) of
        #fwd_rule{listener_pid = LPid} = _Rule when is_pid(LPid) ->
            ok = stop_local_listener(LPid);
        _ ->
            ok
    end,
    Rules = maps:remove(RuleId, S#st.rules),
    {reply, {ok, true}, S#st{rules = Rules}};

handle_call(list, _From, S) ->
    Items = maps:fold(fun(RuleId, R, Acc) ->
        [#{rule_id => RuleId,
           type => atom_to_binary(R#fwd_rule.type, utf8),
           local_port => R#fwd_rule.local_port,
           remote_host => R#fwd_rule.remote_host,
           remote_port => R#fwd_rule.remote_port,
           enabled => R#fwd_rule.enabled} | Acc]
    end, [], S#st.rules),
    {reply, {ok, Items}, S};

handle_call(_Req, _From, S) ->
    {reply, {error, not_implemented}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%% ---------- Internal ----------

gen_rule_id(S) ->
    ConnIdShort = binary:part(S#st.conn_id, {0, erlang:min(byte_size(S#st.conn_id), 16)}),
    <<"fwd_", ConnIdShort/binary, "_", (integer_to_binary(S#st.next_seq))/binary>>.

%% @doc Start a local TCP listener that forwards to remote via SSH direct_tcpip.
start_local_listener(SshRef, #fwd_rule{local_port = Port,
                                        remote_host = RHost,
                                        remote_port = RPort}) ->
    case gen_tcp:listen(Port, [{ip, {127, 0, 0, 1}}, {active, false},
                                {reuseaddr, true}]) of
        {ok, ListenSock} ->
            Pid = spawn_link(fun() ->
                local_listener_loop(ListenSock, SshRef,
                    binary_to_list(RHost), RPort)
            end),
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

local_listener_loop(ListenSock, SshRef, RHost, RPort) ->
    case gen_tcp:accept(ListenSock) of
        {ok, ClientSock} ->
            spawn(fun() -> handle_local_forward(ClientSock, SshRef, RHost, RPort) end),
            local_listener_loop(ListenSock, SshRef, RHost, RPort);
        {error, _} ->
            ok
    end.

handle_local_forward(ClientSock, SshRef, RHost, RPort) ->
    case ssh_connection:direct_tcpip(SshRef, RHost, RPort, "127.0.0.1", 0, ?RPC_DEFAULT_TIMEOUT_MS) of
        {ok, ChanId} ->
            inet:setopts(ClientSock, [{active, once}]),
            forward_loop(ClientSock, SshRef, ChanId);
        {error, _} ->
            gen_tcp:close(ClientSock)
    end.

forward_loop(ClientSock, SshRef, ChanId) ->
    receive
        {ssh_cm, SshRef, {data, ChanId, _Type, Data}} ->
            gen_tcp:send(ClientSock, Data),
            forward_loop(ClientSock, SshRef, ChanId);
        {ssh_cm, SshRef, {eof, ChanId}} ->
            gen_tcp:close(ClientSock),
            ssh_connection:close(SshRef, ChanId);
        {ssh_cm, SshRef, {closed, ChanId}} ->
            gen_tcp:close(ClientSock);
        {tcp, ClientSock, ClientData} ->
            ssh_connection:send(SshRef, ChanId, ClientData),
            inet:setopts(ClientSock, [{active, once}]),
            forward_loop(ClientSock, SshRef, ChanId);
        {tcp_closed, ClientSock} ->
            ssh_connection:close(SshRef, ChanId);
        {tcp_error, ClientSock, _} ->
            ssh_connection:close(SshRef, ChanId)
    after 300000 ->
        %% 5 minute idle timeout
        gen_tcp:close(ClientSock),
        ssh_connection:close(SshRef, ChanId)
    end.

stop_local_listener(Pid) when is_pid(Pid) ->
    _ = (catch exit(Pid, shutdown)),
    ok;
stop_local_listener(_) ->
    ok.

%% @doc Find the port_fwd manager for a connection.
find_mgr(ConnId) ->
    case ets:lookup(portfwd_index, ConnId) of
        [{_, Pid}] -> {ok, Pid};
        [] -> {error, not_found}
    end.

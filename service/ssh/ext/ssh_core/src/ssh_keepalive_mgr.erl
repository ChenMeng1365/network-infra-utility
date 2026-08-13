-module(ssh_keepalive_mgr).
-behaviour(gen_server).

%% Keepalive manager — periodically checks all active connections.
%%
%% Key design (LLD §6.9):
%%   - Periodically sends SSH keepalive to all ready connections
%%   - 3 consecutive failures → push conn.closed (NOT autonomous reconnection)
%%   - Reconnect decision is Ruby's, via conn.reconnect RPC
%%   - Runs as permanent worker in ssh_infra_sup
%%
%% Activity-aware keepalive (enhancement):
%%   - Tracks last_activity timestamp per connection
%%   - If data flowed since last check, skip keepalive and reset fail count
%%   - notify_activity/1 called by channel_stm on send/recv
%%   - This prevents unnecessary keepalive on active connections

-export([start_link/1, set_interval/1, get_interval/0, notify_activity/1, get_status/0,
         rpc_set_interval/1, rpc_get_interval/1, rpc_get_status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("ssh_ipc.hrl").

-record(st, {
    interval_ms :: pos_integer(),
    fail_counts = #{} :: #{pid() => non_neg_integer()},
    last_activity = #{} :: #{pid() => erlang:timestamp()},
    last_check = #{} :: #{pid() => erlang:timestamp()}
}).

%% ---------- Public API ----------

%% @doc Start the keepalive manager with the given interval (ms).
start_link(IntervalMs) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [IntervalMs], []).

%% @doc Update the keepalive interval at runtime.
set_interval(NewMs) ->
    gen_server:cast(?MODULE, {set_interval, NewMs}).

%% @doc Get the current interval.
get_interval() ->
    gen_server:call(?MODULE, get_interval).

%% @doc Notify that activity occurred on a connection (data sent/received).
%% Resets the fail counter and updates the last_activity timestamp.
%% Called by ssh_channel_stm when data flows through a channel.
-spec notify_activity(pid()) -> ok.
notify_activity(ConnWorkerPid) ->
    gen_server:cast(?MODULE, {notify_activity, ConnWorkerPid}).

%% @doc Get keepalive status for all connections (for debugging/monitoring).
get_status() ->
    gen_server:call(?MODULE, get_status).

%% ---------- gen_server callbacks ----------

init([IntervalMs]) ->
    schedule_tick(IntervalMs),
    {ok, #st{interval_ms = IntervalMs}}.

handle_call(get_interval, _From, #st{interval_ms = Ms} = S) ->
    {reply, Ms, S};

handle_call(get_status, _From, #st{fail_counts = Fails, last_activity = Acts} = S) ->
    Workers = ssh_conn_sup:all_workers(),
    Status = lists:map(fun(Pid) ->
        #{
            pid => Pid,
            conn_id => catch ssh_conn_worker:conn_id(Pid),
            state => catch ssh_conn_worker:get_state_name(Pid),
            fail_count => maps:get(Pid, Fails, 0),
            last_activity => maps:get(Pid, Acts, undefined)
        }
    end, Workers),
    {reply, Status, S};

handle_call(_Req, _From, S) ->
    {reply, {error, not_implemented}, S}.

handle_cast({set_interval, NewMs}, #st{} = S) ->
    {noreply, S#st{interval_ms = NewMs}};

handle_cast({notify_activity, ConnWorkerPid}, #st{last_activity = Acts, fail_counts = Fails} = S) ->
    %% Record activity timestamp and reset fail count for this connection
    NewActs = maps:put(ConnWorkerPid, os:timestamp(), Acts),
    NewFails = maps:remove(ConnWorkerPid, Fails),
    {noreply, S#st{last_activity = NewActs, fail_counts = NewFails}};

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(tick, #st{interval_ms = Ms, fail_counts = Fails, last_activity = Acts, last_check = Checks} = S) ->
    %% Scan all connection workers
    Workers = ssh_conn_sup:all_workers(),
    %% Record check time for each worker
    Now = os:timestamp(),
    Checks1 = lists:foldl(fun(Pid, Acc) -> maps:put(Pid, Now, Acc) end, Checks, Workers),
    %% Check each worker, passing the *previous* check timestamps for comparison
    {NewFails, NewActs} = lists:foldl(fun(Pid, {FAcc, AAcc}) ->
        check_keepalive(Pid, FAcc, AAcc, Checks)
    end, {Fails, Acts}, Workers),
    %% Clean up dead workers from maps
    {CleanFails, CleanActs} = cleanup_maps(Workers, NewFails, NewActs),
    schedule_tick(Ms),
    {noreply, S#st{fail_counts = CleanFails, last_activity = CleanActs, last_check = Checks1}};

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

%% ---------- Internal ----------

schedule_tick(IntervalMs) ->
    erlang:send_after(IntervalMs, self(), tick),
    ok.

%% @doc Check a single connection's keepalive.
%% Activity-aware: if data flowed since last check, skip keepalive and reset fail count.
%% Args: Pid, fail_counts, last_activity, last_check (previous check timestamps map)
%% Returns {updated_fail_counts, updated_last_activity}.
check_keepalive(Pid, Fails, Acts, Checks) ->
    case catch ssh_conn_worker:get_state_name(Pid) of
        ready ->
            LastActivity = maps:get(Pid, Acts, undefined),
            LastCheck = maps:get(Pid, Checks, undefined),
            %% Check if there was activity since we last checked
            case was_active_since(LastActivity, LastCheck) of
                true ->
                    %% Connection was active since last check — skip keepalive, reset fails
                    {maps:remove(Pid, Fails), Acts};
                false ->
                    %% No recent activity — send keepalive
                    case send_keepalive(Pid) of
                        ok ->
                            {maps:remove(Pid, Fails), Acts};
                        {error, _} ->
                            Count = maps:get(Pid, Fails, 0) + 1,
                            case Count >= ?KEEPALIVE_DEFAULT_MAX_FAIL of
                                true ->
                                    %% 3 consecutive failures — notify Ruby
                                    ConnId = (catch ssh_conn_worker:conn_id(Pid)),
                                    ssh_ipc_gateway:push_event(<<"conn.closed">>, #{
                                        <<"conn_id">> => ConnId,
                                        <<"reason">> => <<"keepalive_failed">>
                                    }),
                                    {maps:remove(Pid, Fails), maps:remove(Pid, Acts)};
                                false ->
                                    {maps:put(Pid, Count, Fails), Acts}
                            end
                    end
            end;
        _ ->
            %% Not in ready state — skip
            {Fails, Acts}
    end.

%% @doc Check if last_activity is more recent than last_check.
%% Returns true if activity occurred since the last keepalive check.
%% If last_check is undefined (first check), activity doesn't matter — we still send keepalive.
was_active_since(undefined, _LastCheck) ->
    false;
was_active_since(_LastActivity, undefined) ->
    %% First check, no previous check time — don't skip
    false;
was_active_since(LastActivity, LastCheck) ->
    %% Compare timestamps: if LastActivity > LastCheck, there was activity
    try
        Diff = timer:now_diff(LastActivity, LastCheck),
        Diff > 0
    catch
        _:_ -> false
    end.

%% @doc Remove entries for workers that no longer exist.
cleanup_maps(Workers, Fails, Acts) ->
    WorkerSet = sets:from_list(Workers),
    CleanFails = maps:filter(fun(Pid, _) -> sets:is_element(Pid, WorkerSet) end, Fails),
    CleanActs = maps:filter(fun(Pid, _) -> sets:is_element(Pid, WorkerSet) end, Acts),
    {CleanFails, CleanActs}.

%% @doc Send a keepalive packet on an SSH connection.
send_keepalive(Pid) ->
    try
        SshRef = ssh_conn_worker:get_ssh_ref(Pid),
        %% OTP ssh: ssh:send_keepalive/1 — returns ok | {error, Reason}
        ssh:send_keepalive(SshRef)
    catch
        _:_ -> {error, keepalive_exception}
    end.

%% ---------- RPC handlers ----------

%% @doc RPC handler for keepalive.set_interval
rpc_set_interval(#{<<"interval_ms">> := IntervalMs}) ->
    set_interval(IntervalMs),
    #{ok => true}.

%% @doc RPC handler for keepalive.get_interval
rpc_get_interval(_Params) ->
    IntervalMs = get_interval(),
    #{interval_ms => IntervalMs}.

%% @doc RPC handler for keepalive.get_status
rpc_get_status(_Params) ->
    Status = get_status(),
    %% Convert records to maps for JSON encoding
    lists:map(fun(Entry) ->
        maps:map(fun
            (pid, Pid) -> list_to_binary(pid_to_list(Pid));
            (conn_id, V) when is_binary(V) -> V;
            (conn_id, _) -> null;
            (state, V) when is_atom(V) -> atom_to_binary(V, utf8);
            (state, _) -> null;
            (fail_count, V) -> V;
            (last_activity, {Mega, Sec, Micro}) ->
                list_to_binary(io_lib:format("~w,~w,~w", [Mega, Sec, Micro]));
            (last_activity, _) -> null
        end, Entry)
    end, Status).

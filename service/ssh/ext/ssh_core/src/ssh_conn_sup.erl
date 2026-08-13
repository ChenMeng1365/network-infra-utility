-module(ssh_conn_sup).
-behaviour(supervisor).

-export([start_link/0, start_child/1, all_workers/0, rpc_connect/1, rpc_list/1]).
-export([init/1]).

%% @doc Start the connection pool supervisor (simple_one_for_one).
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a new connection worker.
%% Spec is the connect_spec() map from the Ruby side.
start_child(Spec) ->
    supervisor:start_child(?MODULE, [Spec]).

%% @doc List all active connection workers (pid list).
all_workers() ->
    [Pid || {_, Pid, _, _} <- supervisor:which_children(?MODULE)].

%% @doc RPC handler for conn.connect
rpc_connect(Params) ->
    {ok, Pid} = start_child(Params),
    %% Triggers the connection sequence, returns {ok, ConnId} | {error, Reason}
    ssh_conn_worker:do_connect(Pid).

%% @doc RPC handler for conn.list
rpc_list(_Params) ->
    lists:map(fun(Pid) ->
        #{id => ssh_conn_worker:conn_id(Pid),
          state => ssh_conn_worker:get_state_name(Pid)}
    end, all_workers()).

%% @doc simple_one_for_one, intensity 100/60s, temporary workers.
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 60
    },
    ChildSpec = #{
        id => ssh_conn_worker,
        start => {ssh_conn_worker, start_link, []},
        restart => temporary,
        shutdown => 10000,
        type => worker,
        modules => [ssh_conn_worker]
    },
    {ok, {SupFlags, [ChildSpec]}}.

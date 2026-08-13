-module(ssh_core_sup).
-behaviour(supervisor).

-export([start_link/0, stop/0]).
-export([init/1]).

%% @doc Start the top-level supervisor.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Graceful shutdown of the entire application.
stop() ->
    gen_server:stop(?MODULE).

%% @doc Top-level supervisor: one_for_one, intensity 5/60s.
%% Children:
%%   1. ssh_infra_sup     — infrastructure layer (gateway, keepalive, known_hosts)
%%   2. ssh_conn_sup      — dynamic connection workers (simple_one_for_one)
%%   3. ssh_sftp_sup      — dynamic SFTP sessions (simple_one_for_one)
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },
    Children = [
        #{
            id => ssh_infra_sup,
            start => {ssh_infra_sup, start_link, []},
            restart => permanent,
            type => supervisor
        },
        #{
            id => ssh_conn_sup,
            start => {ssh_conn_sup, start_link, []},
            restart => permanent,
            type => supervisor
        },
        #{
            id => ssh_sftp_sup,
            start => {ssh_sftp_sup, start_link, []},
            restart => permanent,
            type => supervisor
        }
    ],
    {ok, {SupFlags, Children}}.

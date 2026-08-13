-module(ssh_core_app).
-behaviour(application).

-export([start/2, stop/1]).

%% @doc Application entry point — starts the top-level supervisor.
start(_StartType, _StartArgs) ->
    ssh_core_sup:start_link().

stop(_State) ->
    ok.

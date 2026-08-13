-module(ssh_infra_sup).
-behaviour(supervisor).

-export([start_link/0, generate_endpoint_file/0]).
-export([init/1]).

-include("ssh_ipc.hrl").

%% @doc Start the infrastructure supervisor.
%% Supervises: ssh_known_hosts_proxy, ssh_keepalive_mgr, ssh_ipc_coalesce, ssh_ipc_gateway
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Return the path to the IPC endpoint file for this VM instance.
%% The file is written by generate_endpoint_and_token/0 during init.
generate_endpoint_file() ->
    Tmp = case os:getenv("TMPDIR") of
        false ->
            case os:type() of
                {win32, _} -> os:getenv("TEMP");
                _ -> "/tmp"
            end;
        Dir -> Dir
    end,
    UID = case os:type() of
        {win32, _} -> os:getenv("USERNAME");
        _ -> integer_to_list(os:getuid())
    end,
    filename:join(Tmp, "ssh_core_" ++ UID ++ ".endpoint").

%% @doc one_for_one, intensity 5/60s.
%% Keeping infra processes separate from conn_sup so a single connection
%% crash never cascades to gateway/keepalive/known_hosts.
init([]) ->
    %% Create ETS indices before any workers start
    ets:new(ch_index, [named_table, public, set]),
    ets:new(sftp_index, [named_table, public, set]),
    ets:new(portfwd_index, [named_table, public, set]),

    {ok, EndpointToken} = generate_endpoint_and_token(),
    Children = [
        #{
            id => ssh_known_hosts_proxy,
            start => {ssh_known_hosts_proxy, start_link, []},
            restart => permanent,
            type => worker
        },
        #{
            id => ssh_ipc_coalesce,
            start => {ssh_ipc_coalesce, start_link, []},
            restart => permanent,
            type => worker
        },
        #{
            id => ssh_keepalive_mgr,
            start => {ssh_keepalive_mgr, start_link, [?KEEPALIVE_DEFAULT_INTERVAL_MS]},
            restart => permanent,
            type => worker
        },
        #{
            id => ssh_ipc_gateway,
            start => {ssh_ipc_gateway, start_link, [EndpointToken]},
            restart => permanent,
            type => worker
        }
    ],
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 60
    },
    {ok, {SupFlags, Children}}.

%% @doc Generate IPC auth token, write endpoint file placeholder.
%% Actual port is assigned later by ssh_ipc_gateway:start_listener().
generate_endpoint_and_token() ->
    Token = ssh_codec:encode_b64(crypto:strong_rand_bytes(32)),
    TmpFile = generate_endpoint_file(),
    %% Write placeholder: endpoint line will be rewritten by gateway
    ok = file:write_file(TmpFile, <<"\n", Token/binary>>),
    set_file_perms_600(TmpFile),
    {ok, #{token => Token, file => TmpFile}}.

build_endpoint() ->
    case os:type() of
        {win32, _} ->
            %% On Windows, write a placeholder; actual port is assigned
            %% by ssh_ipc_gateway:start_listener() after gen_tcp:listen(0).
            {ok, <<"tcp://127.0.0.1:0">>};
        _ ->
            %% Unix/macOS: Unix socket
            Path = <<"/tmp/ssh_core_", (integer_to_binary(os:getpid()))/binary, ".sock">>,
            {ok, <<"unix:", Path/binary>>}
    end.

select_free_port() ->
    {ok, Sock} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Sock),
    gen_tcp:close(Sock),
    {ok, Port}.

set_file_perms_600(File) ->
    _ = file:change_mode(File, 8#600),
    ok.

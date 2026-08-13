-module(ssh_known_hosts_proxy).
-behaviour(gen_server).

%% Known hosts proxy — mediates host key verification between OTP ssh and Ruby.
%%
%% Key design (LLD §6.10, E7 fix):
%%   - Erlang does NOT persist known_hosts — Ruby handles storage
%%   - ssh_auth_engine key_cb calls verify/3 which queries Ruby via IPC
%%   - Uses synchronous_push (blocking reverse RPC) with 30s timeout
%%   - If Ruby doesn't respond in 30s → reject (safe default)
%%   - Returns: accepted | accepted_once | rejected

-export([
    start_link/0,
    verify/3
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("ssh_ipc.hrl").

-record(st, {}).

%% ---------- Public API ----------

%% @doc Start the known_hosts proxy.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Verify a host key by querying Ruby via IPC.
%% Called by ssh_auth_engine's key_cb callbacks.
%% Blocks until Ruby responds or times out.
-spec verify(string(), inet:port_number(), public_key:public_key()) ->
    accepted | accepted_once | rejected.
verify(Host, Port, Key) ->
    Fingerprint = ssh_codec:fingerprint(Key),
    Req = #{
        <<"method">> => <<"hostkey.resolve">>,
        <<"params">> => #{
            <<"host">> => list_to_binary(Host),
            <<"port">> => Port,
            <<"fingerprint">> => Fingerprint
        }
    },
    case ssh_ipc_gateway:synchronous_push(Req, ?HOSTKEY_RESOLVE_TIMEOUT_MS) of
        {ok, #{<<"action">> := <<"accept">>}} -> accepted;
        {ok, #{<<"action">> := <<"once">>}} -> accepted_once;
        {ok, #{<<"action">> := <<"reject">>}} -> rejected;
        {error, timeout} -> rejected;
        {error, _} -> rejected
    end.

%% ---------- gen_server callbacks ----------

init([]) ->
    {ok, #st{}}.

handle_call(_Req, _From, S) ->
    {reply, {error, not_implemented}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) ->
    ok.

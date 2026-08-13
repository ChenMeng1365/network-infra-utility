-module(ssh_jump_chain).

%% Jump chain builder — constructs multi-level ProxyJump SSH connections.
%%
%% Key design (LLD §6.7, E3/E6 fixes):
%%   - OTP ssh has no ssh:connect_via/2 — cannot stack SSH on existing channel
%%   - V1.0 uses {sock_fun, Fun} option for tunneled connections
%%   - Each jump opens a direct_tcpip channel on the previous SSH connection
%%   - The channel is wrapped as a socket-like Fun for the next ssh:connect
%%   - V1.0 priority: single-hop jump (1 level); multi-hop is V2.0
%%
%% Risk: {sock_fun, Fun} is semi-official in OTP 26. Signature:
%%   Fun(connect, Host, Port, Timeout) -> {ok, Sock} | {error, _}
%%   Fun(close, Sock) -> ok
%%   Fun(send, Sock, Data) -> ok | {error, _}
%%   Fun(recv, Sock, Len, Timeout) -> {ok, Data} | {error, _}

-export([
    build/2,
    direct_connect/1,
    tunneled_connect/2,
    make_sock_fun_from_channel/2
]).

-include("ssh_ipc.hrl").

%% ---------- Public API ----------

%% @doc Build a multi-level jump chain connection.
%% Jumps = [J1, J2, ...] from nearest to farthest.
%% Algorithm:
%%   1. Connect to J1 directly
%%   2. For J2..Jn: open direct_tcpip on previous SSH ref, wrap as sock_fun
%%   3. On final jump: direct_tcpip to target, ssh:connect via sock_fun
%%
%% Returns {ok, FinalSshRef} | {error, Reason}
-spec build(map(), [map()]) -> {ok, reference()} | {error, term()}.
build(TargetSpec, []) ->
    %% No jumps — direct connect
    direct_connect(TargetSpec);
build(TargetSpec, Jumps) ->
    case lists:foldl(fun(Jump, {ok, PrevRef}) ->
                tunneled_connect(PrevRef, Jump);
           (_, {error, _} = E) -> E
        end, direct_connect(hd(Jumps)), tl(Jumps)) of
        {ok, LastJumpRef} -> tunneled_connect(LastJumpRef, TargetSpec);
        {error, _} = E -> E
    end.

%% @doc Direct SSH connection (no tunnel).
-spec direct_connect(map()) -> {ok, reference()} | {error, term()}.
direct_connect(Spec) ->
    Host = binary_to_list(maps:get(<<"host">>, Spec)),
    Port = maps:get(<<"port">>, Spec, 22),
    Opts = ssh_conn_worker:build_ssh_options(Spec),
    ssh:connect(Host, Port, Opts, ?CONNECT_TIMEOUT_MS).

%% @doc Connect through an existing SSH tunnel (previous jump).
%% Opens a direct_tcpip channel on PrevRef, then runs ssh:connect
%% with a custom {sock_fun} that wraps the channel.
-spec tunneled_connect(reference(), map()) -> {ok, reference()} | {error, term()}.
tunneled_connect(PrevRef, Spec) ->
    Host = binary_to_list(maps:get(<<"host">>, Spec)),
    Port = maps:get(<<"port">>, Spec, 22),
    %% Open direct_tcpip channel on the previous SSH connection
    case ssh_connection:direct_tcpip(PrevRef, Host, Port, "127.0.0.1", 0, ?CONNECT_TIMEOUT_MS) of
        {ok, Chan} ->
            SockFun = make_sock_fun_from_channel(PrevRef, Chan),
            Opts = ssh_conn_worker:build_ssh_options(Spec) ++ [{sock_fun, SockFun}],
            ssh:connect(Host, Port, Opts, ?CONNECT_TIMEOUT_MS);
        {error, Reason} ->
            {error, {direct_tcpip_failed, Reason}}
    end.

%% @doc Wrap an SSH direct_tcpip channel as a sock_fun for ssh:connect.
%% This is the highest-risk component in V1.0 — the channel must emulate
%% a TCP socket's connect/close/send/recv semantics.
-spec make_sock_fun_from_channel(reference(), integer()) -> function().
make_sock_fun_from_channel(SshRef, ChanId) ->
    %% OTP ssh sock_fun calls different operations with different arities.
    %% We wrap them all through a single 4-arg dispatch:
    %%   (connect, Host, Port, Timeout)  -> {ok, Sock}
    %%   (close,   Sock,  _,     _)     -> ok
    %%   (send,    Sock,  Data,  _)     -> ok | {error,_}
    %%   (recv,    Sock,  Len,   Timeout) -> {ok, Data} | {error,_}
    fun
        (connect, _Host, _Port, _Timeout) ->
            {ok, {SshRef, ChanId}};
        (close, _Sock, _A3, _A4) ->
            ssh_connection:close(SshRef, ChanId),
            ok;
        (send, _Sock, Data, _A4) ->
            ssh_connection:send(SshRef, ChanId, Data);
        (recv, _Sock, _Len, Timeout) ->
            receive
                {ssh_cm, SshRef, {data, ChanId, _Type, Data}} ->
                    {ok, Data}
            after Timeout ->
                {error, timeout}
            end
    end.

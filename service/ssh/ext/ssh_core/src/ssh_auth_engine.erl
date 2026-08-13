-module(ssh_auth_engine).
-behaviour(ssh_client_key_api).

%% Authentication engine — implements OTP ssh's key_cb behaviour.
%%
%% Key design (LLD §6.4, E1/E2/E7 fixes):
%%   - OTP ssh has no ssh:auth_user/3 — auth is in ssh:connect options
%%   - key_cb callbacks handle host key verification (via known_hosts_proxy)
%%   - key_cb callbacks handle user private key loading
%%   - known_hosts persistence is delegated to client via IPC
%%   - Auth chain (multi-method fallback) creates multiple ssh:connect attempts
%%
%% OTP ssh 6.0.3 (OTP 29) key_cb calling convention:
%%   call_KeyCb(F, Args, Opts) ->
%%     apply(KeyCb, F, Args ++ [[{key_cb_private,KeyCbOpts}|UserOpts]])
%%
%%   is_host_key new style (4-arg + opts => 5-arg total):
%%     is_host_key(Public, [PeerName, IP], Port, Alg, Opts)
%%   is_host_key old style (3-arg + opts => 4-arg total):
%%     is_host_key(Public, PeerName, Alg, Opts)
%%   add_host_key new style (3-arg + opts => 4-arg total):
%%     add_host_key([PeerName, IP], Port, Public, Opts)
%%   add_host_key old style (2-arg + opts => 3-arg total):
%%     add_host_key(PeerName, Public, Opts)

-export([
    %% ssh_client_key_api callbacks
    add_host_key/4,
    add_host_key/3,
    is_host_key/5,
    is_host_key/4,
    user_key/2,
    %% High-level auth
    authenticate_chain/2
]).

-include("ssh_ipc.hrl").

%% ---------- ssh_client_key_api: Host key callbacks (OTP 6.0 — new style) ----------

%% @doc New style is_host_key (5-arg: Public, [PeerName, IP], Port, Alg, Opts).
%% Called by OTP 6.x first; if undef, OTP falls back to 4-arg old style.
-spec is_host_key(public_key:public_key(), [string()], inet:port_number(),
                   atom(), term()) -> boolean().
is_host_key(Key, [PeerName | _], Port, _Algorithm, _Opts) ->
    case ssh_known_hosts_proxy:verify(PeerName, Port, Key) of
        accepted -> true;
        accepted_once -> true;
        rejected -> false
    end.

%% @doc New style add_host_key (4-arg: [PeerName, IP], Port, Public, Opts).
-spec add_host_key([string()], inet:port_number(), public_key:public_key(), term()) ->
    ok | {error, term()}.
add_host_key([PeerName | _], Port, PublicKey, _Opts) ->
    case ssh_known_hosts_proxy:verify(PeerName, Port, PublicKey) of
        accepted -> ok;
        accepted_once -> ok;
        rejected -> {error, host_key_rejected}
    end.

%% ---------- ssh_client_key_api: Host key callbacks (legacy old style) ----------

%% @doc Old style is_host_key (4-arg: Public, PeerName, Alg, Opts).
%% Called by older OTP when 5-arg version is undef.
-spec is_host_key(public_key:public_key(), string(), atom(), term()) -> boolean().
is_host_key(Key, PeerName, _Algorithm, _Opts) ->
    case ssh_known_hosts_proxy:verify(PeerName, 22, Key) of
        accepted -> true;
        accepted_once -> true;
        rejected -> false
    end.

%% @doc Old style add_host_key (3-arg: PeerName, Public, Opts).
-spec add_host_key(string(), public_key:public_key(), term()) ->
    ok | {error, term()}.
add_host_key(PeerName, PublicKey, _Opts) ->
    case ssh_known_hosts_proxy:verify(PeerName, 22, PublicKey) of
        accepted -> ok;
        accepted_once -> ok;
        rejected -> {error, host_key_rejected}
    end.

%% ---------- ssh_client_key_api: User key callback ----------

%% @doc Called by OTP ssh to retrieve the user's private key for publickey auth.
-spec user_key(atom(), term()) -> {ok, term()} | {error, term()}.
user_key(Algorithm, Opts) ->
    %% Algorithm: 'ssh-rsa' | 'ssh-ed25519' | 'ecdsa-sha2-nistp256' ...
    %% Opts is a proplist; auth info stored under 'key_cb_private'
    KeyCbOpts = proplists:get_value(key_cb_private, Opts, []),
    AuthMap = case KeyCbOpts of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    KeyPath = maps:get(<<"key_path">>, AuthMap, undefined),
    Passphrase = maps:get(<<"passphrase">>, AuthMap, undefined),
    case KeyPath of
        undefined -> {error, no_key_path};
        _ -> read_private_key(binary_to_list(KeyPath), Algorithm, Passphrase)
    end.

%% ---------- Authentication chain ----------

%% @doc Multi-method authentication fallback chain.
%% OTP ssh integrates auth into ssh:connect, so each method requires a separate
%% ssh:connect attempt. V1.0 supports: publickey -> password fallback.
%%
%% Returns {ok, SshRef} | {error, Reason}
-spec authenticate_chain(map(), [atom()]) -> {ok, reference()} | {error, term()}.
authenticate_chain(_ConnectCtx, []) ->
    {error, all_auth_methods_failed};
authenticate_chain(ConnectCtx, [Method | Rest]) ->
    Opts = build_opts_for_method(ConnectCtx, Method),
    Host = binary_to_list(maps:get(host, ConnectCtx)),
    Port = maps:get(port, ConnectCtx, 22),
    case ssh:connect(Host, Port, Opts, ?CONNECT_TIMEOUT_MS) of
        {ok, Ref} -> {ok, Ref};
        {error, _} -> authenticate_chain(ConnectCtx, Rest)
    end.

%% ---------- Internal ----------

%% @doc Read a private key file (OpenSSH, PKCS8, SEC1).
read_private_key(Path, _Algorithm, Passphrase) ->
    PwdOpt = case Passphrase of
        undefined -> [];
        Pwd -> [{passphrase, binary_to_list(Pwd)}]
    end,
    case public_key:read_keyfile(Path, PwdOpt) of
        {ok, [Key | _]} -> {ok, Key};
        {ok, Key} -> {ok, Key};
        {error, Reason} -> {error, Reason}
    end.

%% @doc Build ssh:connect options for a specific auth method.
build_opts_for_method(ConnectCtx, publickey) ->
    AuthMap = maps:get(auth, ConnectCtx, #{}),
    [
        {user, binary_to_list(maps:get(user, ConnectCtx))},
        {key_cb, {?MODULE, AuthMap}}
    ];
build_opts_for_method(ConnectCtx, password) ->
    AuthMap = maps:get(auth, ConnectCtx, #{}),
    [
        {user, binary_to_list(maps:get(user, ConnectCtx))},
        {password, binary_to_list(maps:get(<<"password">>, AuthMap))}
    ];
build_opts_for_method(ConnectCtx, keyboard_interactive) ->
    AuthMap = maps:get(auth, ConnectCtx, #{}),
    [
        {user, binary_to_list(maps:get(user, ConnectCtx))},
        {keyboard_interactive, fun(_Prompts, _Ssh) ->
            {ok, [binary_to_list(maps:get(<<"password">>, AuthMap))]}
        end}
    ].

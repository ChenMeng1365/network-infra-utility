%% ssh_ipc.hrl — Shared records, macros, and types for IPC and core modules.

%% ---------- Protocol ----------
-define(PROTOCOL_VER, <<"1.0">>).
-define(MSG_DELIMITER, <<"\n">>).
-define(MAX_MSG_SIZE, 2 * 1024 * 1024).  % 2 MB

%% ---------- Timeouts (ms) ----------
-define(CONNECT_TIMEOUT_MS, 60_000).
-define(RPC_DEFAULT_TIMEOUT_MS, 30_000).
-define(HELLO_ID, 1).
-define(HOSTKEY_RESOLVE_TIMEOUT_MS, 30_000).

%% ---------- Coalesce ----------
-define(COALESCE_TICK_MS, 8).
-define(COALESCE_WATERMARK_BYTES, 16 * 1024).
-define(FLOW_PAUSE_THRESHOLD, 512 * 1024).
-define(FLOW_RESUME_THRESHOLD, 128 * 1024).

%% ---------- Keepalive ----------
-define(KEEPALIVE_DEFAULT_INTERVAL_MS, 30_000).
-define(KEEPALIVE_DEFAULT_MAX_FAIL, 3).

%% ---------- Reconnect ----------
-define(RECONNECT_BASE_MS, 5_000).
-define(RECONNECT_MAX_MS, 60_000).
-define(RECONNECT_MAX_ATTEMPTS, 5).

%% ---------- IPC client record ----------
-record(client, {
    socket :: gen_tcp:socket() | port(),
    authed = false :: boolean(),
    pending = #{} :: #{integer() => {erlang:timestamp(), term()}},
    send_q = queue:new() :: queue:queue(binary()),
    flow_blocked = false :: boolean()
}).

%% ---------- Connection record (conn_worker) ----------
-record(conn, {
    id :: binary(),
    spec :: map(),
    ssh_ref :: reference() | undefined,
    channels = #{} :: #{binary() => pid()},
    next_ch_seq = 1 :: pos_integer(),
    reconnect_count = 0 :: non_neg_integer(),
    options :: [proplists:property()],
    fail_reason :: term() | undefined,
    proxy_sock_fun :: function() | undefined
}).

%% ---------- Channel record (channel_stm) ----------
-record(ch, {
    id :: binary(),
    conn_id :: binary(),
    ssh_ref :: reference(),
    ssh_chan_id :: integer(),
    type :: shell | exec | subsystem,
    term_type :: binary() | undefined,
    cols :: pos_integer(),
    rows :: pos_integer(),
    command :: binary() | undefined,
    coalesce_ref :: pid() | undefined
}).

%% ---------- SFTP session record ----------
-record(sftp, {
    id :: binary(),
    conn_id :: binary(),
    ssh_ref :: reference(),
    sftp_pid :: pid() | undefined
}).

%% ---------- Gateway state ----------
-record(gw_state, {
    listen_sock,
    clients = #{} :: #{reference() => #client{}},
    auth_token :: binary(),
    routes :: #{binary() => {module(), atom()}},
    coalesce_ref :: pid() | undefined
}).

-module(ssh_channel_stm).
-behaviour(gen_statem).

%% Channel state machine — manages a single SSH channel (shell/exec/subsystem).
%% State machine: opening → ready → flowing → eof → closing → closed
%%
%% Key design (LLD §6.5, E9 fix):
%%   - Data pushes go through coalesce buffer, not direct to gateway
%%   - rpc_send/rpc_close/rpc_window_change are public RPC entry points
%%   - Channel is a child of conn_worker (spawn_link), parent death = channel death

-export([
    start_link/4,
    rpc_send/1,
    rpc_close/1,
    rpc_window_change/1,
    feed_data/2,
    notify_eof/2
]).
-export([callback_mode/0, init/1]).
-export([opening/3, ready/3, flowing/3, eof/3, closed/3]).

-include("ssh_ipc.hrl").

%% ---------- Public API ----------

%% @doc Start a channel state machine.
start_link(ChId, ConnId, SshRef, Opts) ->
    gen_statem:start_link(?MODULE, [ChId, ConnId, SshRef, Opts], []).

%% @doc RPC handler for channel.send
rpc_send(#{<<"id">> := ChId, <<"data">> := B64Data}) ->
    case find_by_ch_id(ChId) of
        {ok, Pid} ->
            {ok, Data} = ssh_codec:decode_b64(B64Data),
            gen_statem:call(Pid, {send, Data});
        {error, not_found} ->
            {error, channel_not_found}
    end.

%% @doc RPC handler for channel.close
rpc_close(#{<<"id">> := ChId}) ->
    case find_by_ch_id(ChId) of
        {ok, Pid} ->
            gen_statem:call(Pid, close);
        {error, not_found} ->
            {error, channel_not_found}
    end.

%% @doc RPC handler for channel.window_change
rpc_window_change(#{<<"id">> := ChId, <<"cols">> := Cols, <<"rows">> := Rows}) ->
    case find_by_ch_id(ChId) of
        {ok, Pid} ->
            gen_statem:call(Pid, {window_change, Cols, Rows});
        {error, not_found} ->
            {error, channel_not_found}
    end.

%% @doc Feed data from SSH layer into the channel (called by conn_worker).
feed_data(Pid, Data) ->
    gen_statem:cast(Pid, {data, Data}).

%% @doc Notify channel of EOF from SSH layer.
notify_eof(Pid, Reason) ->
    gen_statem:cast(Pid, {eof, Reason}).

%% ---------- gen_statem callbacks ----------

callback_mode() -> state_functions.

init([ChId, ConnId, SshRef, Opts]) ->
    Data = #ch{
        id = ChId,
        conn_id = ConnId,
        ssh_ref = SshRef,
        ssh_chan_id = 0,  %% assigned after ssh_connection:session_channel
        type = maps:get(type, Opts, shell),
        term_type = maps:get(term_type, Opts, <<"xterm-256color">>),
        cols = maps:get(cols, Opts, 80),
        rows = maps:get(rows, Opts, 24),
        command = maps:get(command, Opts, undefined),
        coalesce_ref = whereis(ssh_ipc_coalesce)
    },
    {ok, opening, Data, [{next_event, internal, open}]}.

%% ---------- State: opening ----------

opening(internal, open, #ch{ssh_ref = Ref, cols = Cols, rows = Rows,
                             term_type = TermType, type = Type,
                             command = Cmd} = D) ->
    %% ssh_connection:session_channel returns {ok, ChanId} | {error, Reason}
    case ssh_connection:session_channel(Ref, ?CONNECT_TIMEOUT_MS) of
        {ok, ChanId} ->
            D1 = D#ch{ssh_chan_id = ChanId},
            ok = init_channel_type(Ref, ChanId, Type, TermType, Cols, Rows, Cmd),
            {next_state, ready, D1};
        {error, Reason} ->
            ssh_ipc_gateway:push_event(<<"channel.eof">>, #{
                <<"id">> => D#ch.id,
                <<"reason">> => atom_to_binary(Reason, utf8)
            }),
            {next_state, closed, D}
    end;

opening({call, From}, _Msg, _D) ->
    {keep_state_and_data, [{reply, From, {error, not_ready}}]}.

%% ---------- State: ready ----------

ready({call, From}, {send, Data}, #ch{ssh_ref = Ref, ssh_chan_id = ChanId, conn_id = ConnId} = D) ->
    ok = ssh_connection:send(Ref, ChanId, Data),
    notify_conn_activity(ConnId),
    {keep_state_and_data, [{reply, From, ok}]};

ready({call, From}, {window_change, Cols, Rows}, #ch{ssh_ref = Ref, ssh_chan_id = ChanId, term_type = TermType} = D) ->
    case TermType of
        undefined -> ok;
        _ -> ssh_connection:ptty_alloc(Ref, ChanId, [{Cols, Rows, 0, 0, TermType}])
    end,
    ok = ssh_connection:window_change(Ref, ChanId, Cols, Rows),
    {keep_state, D#ch{cols = Cols, rows = Rows}, [{reply, From, ok}]};

ready({call, From}, close, #ch{ssh_ref = Ref, ssh_chan_id = ChanId} = D) ->
    ssh_connection:close(Ref, ChanId),
    {next_state, closed, D, [{reply, From, ok}]};

ready(cast, {data, Data}, #ch{conn_id = ConnId} = D) ->
    notify_conn_activity(ConnId),
    push_data(D, Data),
    {next_state, flowing, D};

ready(cast, {eof, Reason}, #ch{id = Id} = D) ->
    ssh_ipc_gateway:push_event(<<"channel.eof">>, #{
        <<"id">> => Id,
        <<"reason">> => atom_to_binary(Reason, utf8)
    }),
    {next_state, eof, D}.

%% ---------- State: flowing ----------

flowing({call, From}, {send, Data}, #ch{ssh_ref = Ref, ssh_chan_id = ChanId, conn_id = ConnId} = D) ->
    ok = ssh_connection:send(Ref, ChanId, Data),
    notify_conn_activity(ConnId),
    {keep_state_and_data, [{reply, From, ok}]};

flowing(cast, {data, Data}, #ch{conn_id = ConnId} = D) ->
    notify_conn_activity(ConnId),
    push_data(D, Data),
    {next_state, flowing, D};

flowing(cast, {eof, Reason}, #ch{id = Id} = D) ->
    ssh_ipc_gateway:push_event(<<"channel.eof">>, #{
        <<"id">> => Id,
        <<"reason">> => atom_to_binary(Reason, utf8)
    }),
    {next_state, eof, D};

flowing({call, From}, close, #ch{ssh_ref = Ref, ssh_chan_id = ChanId} = D) ->
    ssh_connection:close(Ref, ChanId),
    {next_state, closed, D, [{reply, From, ok}]};

flowing({call, From}, {window_change, Cols, Rows}, #ch{ssh_ref = Ref, ssh_chan_id = ChanId} = D) ->
    ssh_connection:window_change(Ref, ChanId, Cols, Rows),
    {keep_state, D#ch{cols = Cols, rows = Rows}, [{reply, From, ok}]}.

%% ---------- State: eof ----------

eof({call, From}, close, #ch{ssh_ref = Ref, ssh_chan_id = ChanId} = D) ->
    ssh_connection:close(Ref, ChanId),
    {next_state, closed, D, [{reply, From, ok}]};

eof({call, From}, _Msg, _D) ->
    {keep_state_and_data, [{reply, From, {error, eof}}]}.

%% ---------- State: closed ----------

closed({call, From}, _Msg, _D) ->
    {keep_state_and_data, [{reply, From, {error, closed}}]}.

%% ---------- Internal ----------

%% @doc Notify keepalive manager that activity occurred on this connection.
%% This resets the keepalive fail counter and postpones the next keepalive check.
notify_conn_activity(ConnId) ->
    case find_conn_worker_by_id(ConnId) of
        {ok, Pid} ->
            ssh_keepalive_mgr:notify_activity(Pid);
        {error, _} ->
            ok
    end.

%% @doc Find a connection worker by conn_id.
find_conn_worker_by_id(ConnId) ->
    Match = [Pid || Pid <- ssh_conn_sup:all_workers(),
                    catch ssh_conn_worker:conn_id(Pid) =:= ConnId],
    case Match of
        [Pid | _] -> {ok, Pid};
        [] -> {error, not_found}
    end.

%% @doc Initialize channel type (shell, exec, subsystem).
init_channel_type(Ref, ChanId, shell, TermType, Cols, Rows, _Cmd) ->
    %% OTP 17 ptty_alloc expects a list containing one {Cols, Rows, PixW, PixH, TermType} tuple
    ok = ssh_connection:ptty_alloc(Ref, ChanId, [{Cols, Rows, 0, 0, TermType}]),
    ok = ssh_connection:shell(Ref, ChanId);
init_channel_type(Ref, ChanId, exec, _TermType, _Cols, _Rows, Cmd) when is_binary(Cmd) ->
    ok = ssh_connection:exec(Ref, ChanId, binary_to_list(Cmd), ?CONNECT_TIMEOUT_MS);
init_channel_type(Ref, ChanId, subsystem, _TermType, _Cols, _Rows, Subsystem) when is_binary(Subsystem) ->
    ok = ssh_connection:subsystem(Ref, ChanId, binary_to_list(Subsystem), ?CONNECT_TIMEOUT_MS);
init_channel_type(_, _, _, _, _, _, _) ->
    ok.

%% @doc Push data through coalesce buffer (E9 fix).
push_data(#ch{coalesce_ref = CoalesceRef, id = ChId}, Data) ->
    case CoalesceRef of
        undefined ->
            %% Fallback: direct push (degraded mode)
            ssh_ipc_gateway:push_event(<<"channel.data">>, #{
                <<"id">> => ChId,
                <<"data">> => ssh_codec:encode_b64(Data)
            });
        Ref ->
            ssh_ipc_coalesce:enqueue(Ref, ChId, Data)
    end.

%% @doc Find a channel process by channel_id.
%% Uses ETS index (ch_index) maintained by conn_worker on channel open/close.
find_by_ch_id(ChId) ->
    case ets:lookup(ch_index, ChId) of
        [{_, Pid}] -> {ok, Pid};
        [] -> {error, not_found}
    end.

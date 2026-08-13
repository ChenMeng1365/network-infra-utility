-module(ssh_ipc_coalesce).
-behaviour(gen_server).

%% High-frequency push coalescer with backpressure watermark.
%% Receives per-channel data via enqueue/2 and flushes batched
%% channel.data.batch pushes every COALESCE_TICK_MS or when
%% the buffer reaches COALESCE_WATERMARK_BYTES.

-export([start_link/0, enqueue/3, pause/1, resume/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-include("ssh_ipc.hrl").

-record(st, {
    buffer = #{} :: #{binary() => [binary()]},  % channel_id => [data]
    buffer_size = 0 :: non_neg_integer(),
    tick_ref :: reference() | undefined
}).

%% ---------- Public API ----------

%% @doc Start the coalesce gen_server.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Enqueue data for a channel. Called by ssh_channel_stm.
enqueue(CoalesceRef, ChannelId, Data) ->
    gen_server:cast(CoalesceRef, {enqueue, ChannelId, Data}).

%% @doc Signal flow pause for a channel (backpressure).
pause(ChannelId) ->
    gen_server:cast(?MODULE, {pause, ChannelId}).

%% @doc Signal flow resume for a channel.
resume(ChannelId) ->
    gen_server:cast(?MODULE, {resume, ChannelId}).

%% ---------- Callbacks ----------

init([]) ->
    TickRef = schedule_tick(),
    {ok, #st{tick_ref = TickRef}}.

handle_call(_Req, _From, State) ->
    {reply, {error, not_implemented}, State}.

handle_cast({enqueue, ChannelId, Data}, #st{buffer = Buf, buffer_size = Sz} = S) ->
    NewBuf = maps:update_with(ChannelId, fun(Items) -> Items ++ [Data] end, [Data], Buf),
    NewSz = Sz + byte_size(Data),
    S1 = S#st{buffer = NewBuf, buffer_size = NewSz},
    %% Flush immediately if watermark reached
    S2 = case NewSz >= ?COALESCE_WATERMARK_BYTES of
        true -> do_flush(S1);
        false -> S1
    end,
    {noreply, S2};

handle_cast({pause, ChannelId}, S) ->
    ssh_ipc_gateway:push_event(<<"channel.flow.pause">>, #{<<"channel_id">> => ChannelId}),
    {noreply, S};

handle_cast({resume, ChannelId}, S) ->
    ssh_ipc_gateway:push_event(<<"channel.flow.resume">>, #{<<"channel_id">> => ChannelId}),
    {noreply, S};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(tick, S) ->
    S1 = do_flush(S),
    S2 = S1#st{tick_ref = schedule_tick()},
    {noreply, S2};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ---------- Internal ----------

schedule_tick() ->
    erlang:send_after(?COALESCE_TICK_MS, self(), tick).

%% @doc Flush the coalesce buffer as a channel.data.batch push.
do_flush(#st{buffer = Buf} = S) when map_size(Buf) =:= 0 ->
    S;
do_flush(#st{buffer = Buf} = S) ->
    Items = maps:fold(fun(ChId, Datas, Acc) ->
        B64 = ssh_codec:encode_b64(iolist_to_binary(Datas)),
        [#{<<"id">> => ChId, <<"data">> => B64} | Acc]
    end, [], Buf),
    ssh_ipc_gateway:push_batch(#{<<"items">> => Items}),
    S#st{buffer = #{}, buffer_size = 0}.

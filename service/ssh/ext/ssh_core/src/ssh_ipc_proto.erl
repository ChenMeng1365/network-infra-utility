-module(ssh_ipc_proto).
%% JSON-RPC 2.0 protocol encode/decode and framing.
%% Pure module — no network I/O, no state.

-export([
    encode_request/3,
    encode_response/2,
    encode_error/3,
    encode_push/2,
    decode/1,
    frame/1,
    unframe/1
]).

%% ---------- Encoding ----------

%% @doc Encode a JSON-RPC request.
-spec encode_request(integer(), binary(), map()) -> binary().
encode_request(Id, Method, Params) ->
    ssh_codec:encode_json(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"method">> => Method,
        <<"params">> => Params
    }).

%% @doc Encode a successful response.
-spec encode_response(integer(), map()) -> binary().
encode_response(Id, Result) ->
    ssh_codec:encode_json(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"result">> => Result
    }).

%% @doc Encode an error response.
-spec encode_error(integer(), integer(), map()) -> binary().
encode_error(Id, Code, ErrorObj) ->
    ssh_codec:encode_json(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"id">> => Id,
        <<"error">> => ErrorObj#{<<"code">> => Code}
    }).

%% @doc Encode a push notification (no id).
-spec encode_push(binary(), map()) -> binary().
encode_push(Method, Params) ->
    ssh_codec:encode_json(#{
        <<"jsonrpc">> => <<"2.0">>,
        <<"method">> => Method,
        <<"params">> => Params
    }).

%% ---------- Decoding ----------

%% @doc Decode a single JSON-RPC message (binary, no delimiter).
%% Returns {ok, Map} | {error, Reason}.
-spec decode(binary()) -> {ok, map()} | {error, term()}.
decode(Bin) ->
    case ssh_codec:decode_json(Bin) of
        {ok, Map} when is_map(Map) -> validate_msg(Map);
        {error, _} = E -> E
    end.

%% ---------- Framing ----------

%% @doc Append newline delimiter to a message.
-spec frame(binary()) -> binary().
frame(Msg) ->
    <<Msg/binary, "\n">>.

%% @doc Split a buffer on newline delimiters.
%% Returns {[MessageBinaries], RemainingBuffer}.
-spec unframe(binary()) -> {[binary()], binary()}.
unframe(Buffer) ->
    split_frames(Buffer, []).

%% ---------- Internal ----------

validate_msg(#{<<"jsonrpc">> := <<"2.0">>} = Msg) ->
    case maps:is_key(<<"id">>, Msg) of
        true -> {ok, {request_or_response, Msg}};
        false -> {ok, {notification, Msg}}
    end;
validate_msg(_) ->
    {error, invalid_jsonrpc}.

split_frames(Buffer, Acc) ->
    case binary:match(Buffer, <<"\n">>) of
        {Pos, _} ->
            <<Frame:Pos/binary, _:8, Rest/binary>> = Buffer,
            split_frames(Rest, [Frame | Acc]);
        nomatch ->
            {lists:reverse(Acc), Buffer}
    end.

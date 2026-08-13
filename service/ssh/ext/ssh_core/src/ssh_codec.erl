-module(ssh_codec).
%% Shared encoding/decoding utilities: Base64, JSON, fingerprint, ID generation.

-export([
    encode_json/1,
    decode_json/1,
    encode_b64/1,
    decode_b64/1,
    unix_ms/0,
    gen_conn_id/0,
    gen_channel_id/1,
    gen_sftp_id/1,
    gen_rule_id/1,
    fingerprint/1
]).

%% @doc Encode a map to JSON binary (via jsx).
-spec encode_json(map() | list()) -> binary().
encode_json(Term) ->
    jsx:encode(Term).

%% @doc Decode a JSON binary to map.
-spec decode_json(binary()) -> {ok, map()} | {error, term()}.
decode_json(Bin) ->
    try jsx:decode(Bin, [return_maps]) of
        Map -> {ok, Map}
    catch
        _:_ -> {error, parse_error}
    end.

%% @doc Base64 encode binary data.
-spec encode_b64(binary()) -> binary().
encode_b64(Data) ->
    base64:encode(Data).

%% @doc Base64 decode a binary or string.
-spec decode_b64(binary() | string()) -> {ok, binary()} | {error, term()}.
decode_b64(Data) ->
    try {ok, base64:decode(Data)}
    catch _:_ -> {error, bad_b64} end.

%% @doc Current Unix timestamp in milliseconds.
-spec unix_ms() -> integer().
unix_ms() ->
    erlang:system_time(millisecond).

%% @doc Generate a connection ID: conn_<unix_ms>_<8hex>
-spec gen_conn_id() -> binary().
gen_conn_id() ->
    Ts = integer_to_binary(unix_ms()),
    Rand = binary:encode_hex(crypto:strong_rand_bytes(4)),
    <<"conn_", Ts/binary, "_", Rand/binary>>.

%% @doc Generate a channel ID within a connection.
-spec gen_channel_id(binary()) -> binary().
gen_channel_id(ConnId) ->
    ConnShort = binary:part(ConnId, {0, erlang:min(byte_size(ConnId), 16)}),
    Seq = integer_to_binary(unix_ms() rem 100000),
    <<"ch_", ConnShort/binary, "_", Seq/binary>>.

%% @doc Generate an SFTP session ID.
-spec gen_sftp_id(binary()) -> binary().
gen_sftp_id(ConnId) ->
    ConnShort = binary:part(ConnId, {0, erlang:min(byte_size(ConnId), 16)}),
    Ts = integer_to_binary(unix_ms()),
    <<"sftp_", ConnShort/binary, "_", Ts/binary>>.

%% @doc Generate a port-forward rule ID.
-spec gen_rule_id(binary()) -> binary().
gen_rule_id(ConnId) ->
    ConnShort = binary:part(ConnId, {0, erlang:min(byte_size(ConnId), 16)}),
    <<"fwd_", ConnShort/binary>>.

%% @doc Compute SHA-256 fingerprint of a public key in OpenSSH format.
%% Returns <<"SHA256:base64...">>
%%
%% In OTP < 24, public_key:ssh_encode/2 was available, but OTP 24+ moved the
%% encoding into ssh_message:ssh2_pubkey_encode/1.  We use ssh:hostkey_fingerprint/2
%% which wraps that and returns the canonical "SHA256:..." string.
-spec fingerprint(term()) -> binary().
fingerprint(PublicKey) ->
    %% ssh:hostkey_fingerprint/2 returns a string() like "SHA256:base64..."
    list_to_binary(ssh:hostkey_fingerprint(sha256, PublicKey)).

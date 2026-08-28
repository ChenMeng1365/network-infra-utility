#!/usr/bin/env escript
%% packbit — Erlang pcap parser, config-driven filter/stats/display
%% core: Erlang protocol parsing engine | CLI: Ruby wrapper (bin/packbit)
%% usage: escript packbit.erl -f <pcap> [-c <config.yml>] [-d] [-p <port> <proto>]

%%%% CLI %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

main(Args) ->
    O = pa(Args, #{f => nil, c => nil, d => false, p => nil, t => nil}),
    F = maps:get(f, O),
    if F =:= nil ->
        io:format("usage: packbit -f <pcap> [-c <config.yml>] [-d] [-p <port> <proto>]~n"),
        halt(1);
    true ->
        Cfg = load_cfg(O),
        {LT, Pkts} = read_pcap(F),
        Fr = [{byte_size(D), parse_frame(D, LT)} || {_, D} <- Pkts],
        F1 = apply_filter(Fr, Cfg),
        case get_in(Cfg, [display, mode], detail) of
            summary -> show_summary(F1, Cfg, LT, length(Pkts));
            detail  -> show_detail(F1, Cfg, LT, length(Pkts))
        end
    end.

pa([], A) -> A;
pa(["-f", F | R], A) -> pa(R, A#{f => F});
pa(["-c", C | R], A) -> pa(R, A#{c => C});
pa(["-d" | R], A) -> pa(R, A#{d => true});
pa(["-p", P, T | R], A) ->
    Port = try list_to_integer(P) catch _:_ -> P end,
    pa(R, A#{p => Port, t => T});
pa(["-h" | _], _) -> usage(), halt(0);
pa(["-v" | _], _) -> io:format("packbit 0.1~n"), halt(0);
pa([_ | R], A) -> pa(R, A).

usage() ->
    io:format("packbit — Erlang pcap parser (config-driven)~n~n"),
    io:format("usage: packbit -f <pcap> [-c <config.yml>] [-d] [-p <port> <proto>]~n~n"),
    io:format("  -f <file>     pcap file to parse~n"),
    io:format("  -c <config>   YAML config (filter/stats/display)~n"),
    io:format("  -d            summary mode (stats + per-frame)~n"),
    io:format("  -p <port> <proto>  filter by port + protocol~n"),
    io:format("  -h            help~n"),
    io:format("  -v            version~n").

%%%% Config %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

load_cfg(O) ->
    Base = #{
        filter  => #{protocol => [], port => nil, ip => nil},
        stats   => #{group_by => stack, top => 0, sort => desc, sort_by => count},
        display => #{mode => detail, fields => [], payload => true, color => false}
    },
    CF = maps:get(c, O),
    C0 = case CF of
        nil -> Base;
        _ -> case file:read_file(CF) of
            {ok, B} ->
                case parse_yaml(B) of
                    nil -> Base;
                    Parsed -> dmerge(Base, Parsed)
                end;
            _ -> Base
        end
    end,
    C1 = case maps:get(d, O) of true -> dput(C0, [display, mode], summary); _ -> C0 end,
    case {maps:get(p, O), maps:get(t, O)} of
        {nil, _} -> C1;
        {Port, Proto} ->
            dput(dput(C1, [filter, port], Port), [filter, protocol], [list_to_atom(Proto)])
    end.

dmerge(A, nil) when is_map(A) -> A;
dmerge(A, B) when is_map(A), is_map(B) ->
    maps:fold(fun(K, V, Acc) ->
        case maps:is_key(K, Acc) andalso is_map(maps:get(K, Acc)) andalso is_map(V) of
            true -> Acc#{K => dmerge(maps:get(K, Acc), V)};
            _ -> Acc#{K => V}
        end
    end, A, B);
dmerge(_, B) -> B.

dput(M, [K], V) -> M#{K => V};
dput(M, [K | Path], V) -> M#{K => dput(maps:get(K, M, #{}), Path, V)}.

get_in(M, [K], Def) -> maps:get(K, M, Def);
get_in(M, [K | Path], Def) ->
    case maps:get(K, M, nil) of
        nil -> Def;
        Sub -> get_in(Sub, Path, Def)
    end.

%%%% Minimal YAML Parser %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse_yaml(Bin) when is_binary(Bin) ->
    Lines = ylines(Bin),
    {Result, []} = ynode(Lines, 0),
    Result.

ylines(Bin) ->
    Text = re:replace(binary_to_list(Bin), "\r\n", "\n", [global, {return, list}]),
    Raw = string:split(Text, "\n", all),
    lists:filtermap(fun(L) ->
        S = strip_comment(L),
        T = string:trim(S),
        case T of
            "" -> false;
            _ -> {true, {indent_of(L), T}}
        end
    end, Raw).

indent_of(L) ->
    {Pre, _} = lists:splitwith(fun(C) -> C =:= $\s end, L),
    length(Pre).

strip_comment(L) ->
    hd(string:split(L, "#", leading)).

%% ynode: parse a block (map or list) at minimum indent
ynode([], _MinI) -> {nil, []};
ynode([{I, _} | _] = L, MinI) when I < MinI -> {nil, L};
ynode([{I, C} | _R], _MinI) ->
    case C of
        [$- | _] -> ylist([{I, C} | _R], I, []);
        _ -> ymap([{I, C} | _R], I, #{})
    end.

%% ymap: parse key-value pairs at given indent
ymap([], _I, Acc) -> {Acc, []};
ymap([{I, _} | _] = L, Indent, Acc) when I < Indent -> {Acc, L};
ymap([{I, C} | R], Indent, Acc) ->
    case string:split(C, ":", leading) of
        [K, ""] ->
            {V, Rem} = ynode(R, I + 1),
            ymap(Rem, Indent, Acc#{list_to_atom(string:trim(K)) => V});
        [K, V] ->
            ymap(R, Indent, Acc#{list_to_atom(string:trim(K)) => parse_scalar(string:trim(V))})
    end.

%% ylist: parse list items at given indent
ylist([], _I, Acc) -> {lists:reverse(Acc), []};
ylist([{I, _} | _] = L, Indent, Acc) when I < Indent -> {lists:reverse(Acc), L};
ylist([{_I, [$- | ItemStr]} | R], Indent, Acc) ->
    Item = parse_scalar(string:trim(ItemStr, leading, " \t")),
    ylist(R, Indent, [Item | Acc]).

parse_scalar("true") -> true;
parse_scalar("false") -> false;
parse_scalar("nil") -> nil;
parse_scalar("null") -> nil;
parse_scalar("[]") -> [];
parse_scalar("{}") -> #{};
parse_scalar(S) ->
    case string:to_integer(S) of
        {N, ""} -> N;
        _ ->
            case is_simple_atom(S) of
                true -> list_to_atom(S);
                false -> S
            end
    end.

is_simple_atom([]) -> false;
is_simple_atom(S) -> lists:all(fun is_atom_char/1, S).
is_atom_char(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                   orelse (C >= $0 andalso C =< $9) orelse C =:= $_.

%%%% Pcap Reader %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

read_pcap(File) ->
    {ok, Bin} = file:read_file(File),
    case byte_size(Bin) < 24 of
        true -> erlang:error(too_short);
        false ->
            <<Magic:4/binary, GH:20/binary, Rest/binary>> = Bin,
            case Magic of
                <<16#d4, 16#c3, 16#b2, 16#a1>> ->
                    <<_:16/little, _:16/little, _:32/little, _:32/little, _:32/little, LT:32/little>> = GH,
                    {LT, read_pkts_le(Rest, [])};
                <<16#a1, 16#b2, 16#c3, 16#d4>> ->
                    <<_:16/big, _:16/big, _:32/big, _:32/big, _:32/big, LT:32/big>> = GH,
                    {LT, read_pkts_be(Rest, [])};
                <<16#4d, 16#3c, 16#b2, 16#a1>> ->
                    <<_:16/little, _:16/little, _:32/little, _:32/little, _:32/little, LT:32/little>> = GH,
                    {LT, read_pkts_le(Rest, [])};
                <<16#a1, 16#b2, 16#3c, 16#4d>> ->
                    <<_:16/big, _:16/big, _:32/big, _:32/big, _:32/big, LT:32/big>> = GH,
                    {LT, read_pkts_be(Rest, [])};
                _ -> erlang:error(not_pcap)
            end
    end.

read_pkts_le(<<Ts:32/little, _:32/little, Len:32/little, _:32/little, D:Len/binary, R/binary>>, Acc) ->
    read_pkts_le(R, [{Ts, D} | Acc]);
read_pkts_le(<<>>, Acc) -> lists:reverse(Acc);
read_pkts_le(_, Acc) -> lists:reverse(Acc).

read_pkts_be(<<Ts:32/big, _:32/big, Len:32/big, _:32/big, D:Len/binary, R/binary>>, Acc) ->
    read_pkts_be(R, [{Ts, D} | Acc]);
read_pkts_be(<<>>, Acc) -> lists:reverse(Acc);
read_pkts_be(_, Acc) -> lists:reverse(Acc).

%%%% Protocol Parsers %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse_frame(Data, LT) ->
    case LT of
        1 -> dispatch(Data, 0, ethernet, []);
        _ -> dispatch(Data, 0, ethernet, [])
    end.

dispatch(_D, _O, nil, S) -> lists:reverse(S);
dispatch(_D, _O, _T, S) when length(S) > 20 -> lists:reverse(S);
dispatch(D, O, T, S) ->
    case parse_proto(T, D, O) of
        nil -> lists:reverse(S);
        L ->
            S1 = [L | S],
            NT = maps:get(next_type, L, nil),
            case NT of
                nil -> lists:reverse(S1);
                _ -> dispatch(D, maps:get(offset, L), NT, S1)
            end
    end.

parse_proto(ethernet, D, O) -> parse_eth(D, O);
parse_proto(ipv4, D, O) -> parse_ipv4(D, O);
parse_proto(ipv6, D, O) -> parse_ipv6(D, O);
parse_proto(arp, D, O) -> parse_arp(D, O);
parse_proto(tcp, D, O) -> parse_tcp(D, O);
parse_proto(udp, D, O) -> parse_udp(D, O);
parse_proto(icmp, D, O) -> parse_icmp(D, O);
parse_proto(icmpv6, D, O) -> parse_icmpv6(D, O);
parse_proto(vlan, D, O) -> parse_vlan(D, O);
parse_proto(_, _, _) -> nil.

%% Ethernet II: dst(6B) src(6B) type(2B) = 14B
parse_eth(D, O) ->
    case byte_size(D) >= O + 14 of
        false -> nil;
        true ->
            <<Dst:6/binary, Src:6/binary, Type:16/big>> = binary:part(D, O, 14),
            Next = case Type of
                16#0800 -> ipv4;
                16#0806 -> arp;
                16#86dd -> ipv6;
                16#8100 -> vlan;
                _ -> nil
            end,
            #{proto => ethernet, dst_mac => fmt_mac(Dst), src_mac => fmt_mac(Src),
              eth_type => Type, next_type => Next, offset => O + 14}
    end.

%% 802.1Q VLAN: TCI(2B) + Type(2B) = 4B
parse_vlan(D, O) ->
    case byte_size(D) >= O + 4 of
        false -> nil;
        true ->
            TCI = rd16(D, O),
            Type = rd16(D, O + 2),
            Next = case Type of
                16#0800 -> ipv4;
                16#0806 -> arp;
                16#86dd -> ipv6;
                16#8100 -> vlan;
                _ -> nil
            end,
            #{proto => vlan, pcp => (TCI bsr 13) band 7, dei => (TCI bsr 12) band 1,
              vid => TCI band 16#0FFF, eth_type => Type, next_type => Next, offset => O + 4}
    end.

%% IPv4: ver(4b) ihl(4b) ... proto(8b) src(32b) dst(32b), header = IHL*4
parse_ipv4(D, O) ->
    case byte_size(D) >= O + 20 of
        false -> nil;
        true ->
            B1 = binary:at(D, O),
            IHL = B1 band 16#0F,
            HLen = IHL * 4,
            case byte_size(D) >= O + HLen of
                false -> nil;
                true ->
                    Proto = binary:at(D, O + 9),
                    <<SrcIP:4/binary, DstIP:4/binary>> = binary:part(D, O + 12, 8),
                    Next = case Proto of
                        1 -> icmp; 6 -> tcp; 17 -> udp; 47 -> gre; _ -> nil
                    end,
                    #{proto => ipv4, version => (B1 bsr 4) band 16#0F, ihl => IHL,
                      header_len => HLen, ttl => binary:at(D, O + 8), protocol => Proto,
                      src_ip => fmt_ipv4(SrcIP), dst_ip => fmt_ipv4(DstIP),
                      total_length => rd16(D, O + 2), identification => rd16(D, O + 4),
                      next_type => Next, offset => O + HLen}
            end
    end.

%% IPv6: ver(4b) tc(8b) flow(20b) plen(16b) nh(8b) hlim(8b) src(128b) dst(128b) = 40B
parse_ipv6(D, O) ->
    case byte_size(D) >= O + 40 of
        false -> nil;
        true ->
            NH = binary:at(D, O + 6),
            <<SrcIP:16/binary, DstIP:16/binary>> = binary:part(D, O + 8, 32),
            Next = case NH of
                6 -> tcp; 17 -> udp; 58 -> icmpv6; 47 -> gre; _ -> nil
            end,
            #{proto => ipv6, version => bits(D, O * 8, 4),
              hop_limit => binary:at(D, O + 7), next_header => NH,
              src_ip => fmt_ipv6(SrcIP), dst_ip => fmt_ipv6(DstIP),
              payload_length => rd16(D, O + 4), next_type => Next, offset => O + 40}
    end.

%% ARP: hw(16b) proto(16b) hlen(8b) plen(8b) op(16b) smac(48b) sip(32b) dmac(48b) dip(32b) = 28B
parse_arp(D, O) ->
    case byte_size(D) >= O + 28 of
        false -> nil;
        true ->
            Op = rd16(D, O + 6),
            <<SMac:6/binary, SIP:4/binary, DMac:6/binary, DIP:4/binary>> = binary:part(D, O + 8, 20),
            Opcode = case Op of 1 -> request; 2 -> reply; _ -> Op end,
            #{proto => arp, opcode => Opcode,
              sender_mac => fmt_mac(SMac), sender_ip => fmt_ipv4(SIP),
              target_mac => fmt_mac(DMac), target_ip => fmt_ipv4(DIP),
              next_type => nil, offset => O + 28}
    end.

%% TCP: sport(16b) dport(16b) seq(32b) ack(32b) doff(4b) flags(8b) win(16b) = 20B+
parse_tcp(D, O) ->
    case byte_size(D) >= O + 20 of
        false -> nil;
        true ->
            SP = rd16(D, O),
            DP = rd16(D, O + 2),
            Seq = rd32(D, O + 4),
            Ack = rd32(D, O + 8),
            Doff = bits(D, O * 8 + 96, 4),
            HLen = Doff * 4,
            FB = binary:at(D, O + 13),
            Flags = tcp_flags(FB),
            #{proto => tcp, src_port => SP, dst_port => DP, seq => Seq, ack => Ack,
              header_len => HLen, flags => Flags, window => rd16(D, O + 14),
              next_type => nil, offset => O + HLen}
    end.

%% UDP: sport(16b) dport(16b) len(16b) cksum(16b) = 8B
parse_udp(D, O) ->
    case byte_size(D) >= O + 8 of
        false -> nil;
        true ->
            #{proto => udp, src_port => rd16(D, O), dst_port => rd16(D, O + 2),
              length => rd16(D, O + 4), next_type => nil, offset => O + 8}
    end.

%% ICMP: type(8b) code(8b) cksum(16b) rest(32b) = 8B+
parse_icmp(D, O) ->
    case byte_size(D) >= O + 4 of
        false -> nil;
        true ->
            T = binary:at(D, O),
            Types = #{0 => echo_reply, 8 => echo_request, 3 => dest_unreachable,
                      5 => redirect, 11 => time_exceeded, 13 => timestamp, 14 => timestamp_reply},
            #{proto => icmp, type => maps:get(T, Types, T), code => binary:at(D, O + 1),
              checksum => rd16(D, O + 2), next_type => nil, offset => O + 8}
    end.

%% ICMPv6: type(8b) code(8b) cksum(16b) body(32b+) = 4B+
parse_icmpv6(D, O) ->
    case byte_size(D) >= O + 4 of
        false -> nil;
        true ->
            T = binary:at(D, O),
            Types = #{128 => echo_request, 129 => echo_reply, 1 => dest_unreachable,
                      2 => packet_too_big, 3 => time_exceeded, 133 => router_solicit,
                      134 => router_advert, 135 => neighbor_solicit, 136 => neighbor_advert},
            #{proto => icmpv6, type => maps:get(T, Types, T), code => binary:at(D, O + 1),
              checksum => rd16(D, O + 2), next_type => nil, offset => O + 8}
    end.

%%%% Bit & Format Helpers %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

bits(D, BitOff, Len) when BitOff + Len =< bit_size(D) ->
    <<_:BitOff/bitstring, V:Len/integer-big, _/bitstring>> = D,
    V;
bits(_, _, _) -> 0.

rd16(D, O) -> <<V:16/big>> = binary:part(D, O, 2), V.
rd32(D, O) -> <<V:32/big>> = binary:part(D, O, 4), V.

fmt_mac(<<A, B, C, D, E, F>>) ->
    lists:flatten(io_lib:format("~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B", [A, B, C, D, E, F])).

fmt_ipv4(<<A, B, C, D>>) ->
    lists:flatten(io_lib:format("~B.~B.~B.~B", [A, B, C, D])).

fmt_ipv6(<<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>) ->
    lists:flatten(io_lib:format("~4.16.0B:~4.16.0B:~4.16.0B:~4.16.0B:~4.16.0B:~4.16.0B:~4.16.0B:~4.16.0B",
                                [A, B, C, D, E, F, G, H])).

tcp_flags(B) ->
    Names = [{cwr, 16#80}, {ece, 16#40}, {urg, 16#20}, {ack, 16#10},
             {psh, 16#08}, {rst, 16#04}, {syn, 16#02}, {fin, 16#01}],
    [N || {N, M} <- Names, (B band M) =/= 0].

proto_name(ethernet) -> "Ethernet";
proto_name(ipv4) -> "IPv4";
proto_name(ipv6) -> "IPv6";
proto_name(arp) -> "ARP";
proto_name(tcp) -> "TCP";
proto_name(udp) -> "UDP";
proto_name(icmp) -> "ICMP";
proto_name(icmpv6) -> "ICMPv6";
proto_name(vlan) -> "VLAN";
proto_name(Other) -> atom_to_list(Other).

fmt_val(V) when is_integer(V) -> integer_to_list(V);
fmt_val(V) when is_atom(V) -> atom_to_list(V);
fmt_val(V) when is_binary(V) -> binary_to_list(V);
fmt_val([H | _] = L) when is_atom(H) ->
    "[" ++ string:join([atom_to_list(A) || A <- L], ",") ++ "]";
fmt_val(V) when is_list(V) -> V;
fmt_val(Other) -> lists:flatten(io_lib:format("~p", [Other])).

field_order(ethernet) -> [dst_mac, src_mac, eth_type];
field_order(vlan) -> [pcp, dei, vid, eth_type];
field_order(ipv4) -> [version, ihl, header_len, ttl, protocol, src_ip, dst_ip,
                      total_length, identification];
field_order(ipv6) -> [version, hop_limit, next_header, src_ip, dst_ip, payload_length];
field_order(arp) -> [opcode, sender_mac, sender_ip, target_mac, target_ip];
field_order(tcp) -> [src_port, dst_port, seq, ack, header_len, flags, window];
field_order(udp) -> [src_port, dst_port, length];
field_order(icmp) -> [type, code, checksum];
field_order(icmpv6) -> [type, code, checksum];
field_order(_) -> [].

%%%% Filter %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

apply_filter(Frames, Cfg) ->
    F = get_in(Cfg, [filter], #{}),
    Protos = maps:get(protocol, F, []),
    Port = maps:get(port, F, nil),
    IP = maps:get(ip, F, nil),
    lists:filter(fun({_Sz, Frame}) ->
        proto_match(Frame, Protos) andalso port_match(Frame, Port) andalso ip_match(Frame, IP)
    end, Frames).

proto_match(_Frame, []) -> true;
proto_match(_Frame, nil) -> true;
proto_match(Frame, Protos) when is_list(Protos) ->
    lists:any(fun(L) -> lists:member(maps:get(proto, L, nil), Protos) end, Frame);
proto_match(_, _) -> true.

port_match(_Frame, nil) -> true;
port_match(Frame, Port) ->
    lists:any(fun(L) ->
        maps:get(src_port, L, nil) =:= Port orelse maps:get(dst_port, L, nil) =:= Port
    end, Frame).

ip_match(_Frame, nil) -> true;
ip_match(Frame, IP) ->
    lists:any(fun(L) ->
        maps:get(src_ip, L, nil) =:= IP orelse maps:get(dst_ip, L, nil) =:= IP
    end, Frame).

%%%% Stats %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% group_by 支持两种写法:
%%   1. 单值 (atom): stack | protocol    — 特殊键，不走字段提取
%%   2. 字段列表: [src_ip, dst_ip, src_port, protocol, ...] 任意组合
%%      每个字段名自动从协议栈各层提取，缺失用 "-" 填充
%%      组合键用 " -> " 拼接
%% 兼容: flow = [src_ip, dst_ip], src_ip = [src_ip]

show_summary(Frames, Cfg, LT, Total) ->
    io:format("link_type: ~B  packets: ~B~n", [LT, Total]),
    io:format("== Stats ==~n"),
    Gb = get_in(Cfg, [stats, group_by], stack),
    Groups = group_frames(Frames, Gb),
    SortBy = get_in(Cfg, [stats, sort_by], count),
    Sorted = sort_groups(maps:to_list(Groups), get_in(Cfg, [stats, sort], desc), SortBy),
    Top = get_in(Cfg, [stats, top], 0),
    Result = case Top of 0 -> Sorted; N -> lists:sublist(Sorted, N) end,
    [io:format("  ~-50s  ~5B pkts  ~s~n", [K, C, fmt_bytes(B)]) || {K, {C, B}} <- Result],
    io:format("~n== Per-frame ==~n"),
    case Frames of
        [] -> ok;
        _ ->
            Indexed = lists:zip(lists:seq(0, length(Frames) - 1), Frames),
            [io:format("  ~4w  ~s~n", [I, frame_summary(F)]) || {I, {_S, F}} <- Indexed]
    end.

%% 统一入口: 将 group_by 规范为字段列表后调用通用分组
%% stack / protocol 是特殊键，不拆成字段
group_frames(Frames, stack) ->
    lists:foldl(fun({Sz, F}, Acc) -> inc_stats(frame_summary(F), Sz, Acc) end, #{}, Frames);
group_frames(Frames, protocol) ->
    lists:foldl(fun({Sz, F}, Acc) ->
        inc_stats(proto_name(maps:get(proto, hd(F), unknown)), Sz, Acc)
    end, #{}, Frames);
%% 兼容 flow 别名 = [src_ip, dst_ip]
group_frames(Frames, flow) ->
    group_frames(Frames, [src_ip, dst_ip]);
%% 兼容单个 atom 字段: 自动包成列表
group_frames(Frames, Field) when is_atom(Field) ->
    group_frames(Frames, [Field]);
%% 通用: 任意字段列表组合，自动从协议栈提取
%% [src_ip, dst_ip]  -> "10.0.0.1 -> 8.8.8.8"
%% [src_ip, dst_ip, src_port, dst_port, protocol] -> "10.0.0.1 -> 8.8.8.8 -> 12345 -> 80 -> tcp"
group_frames(Frames, Fields) when is_list(Fields) ->
    lists:foldl(fun({Sz, F}, Acc) ->
        Key = make_key(F, Fields),
        inc_stats(Key, Sz, Acc)
    end, #{}, Frames).

%% 从协议栈各层提取字段值拼成组合键
make_key(Frame, Fields) ->
    Vals = [fmt_key(find_field(Frame, F, nil)) || F <- Fields],
    string:join(Vals, " -> ").

%% 格式化键值: 整数转字符串, atom 转字符串, nil 填 "-"
fmt_key(nil) -> "-";
fmt_key(V) when is_integer(V) -> integer_to_list(V);
fmt_key(V) when is_atom(V) -> atom_to_list(V);
fmt_key(V) when is_list(V) -> V;
fmt_key(Other) -> lists:flatten(io_lib:format("~p", [Other])).

sort_groups(Groups, desc, count) -> lists:sort(fun({_, {A,_}}, {_, {B,_}}) -> A >= B end, Groups);
sort_groups(Groups, asc, count)  -> lists:sort(fun({_, {A,_}}, {_, {B,_}}) -> A =< B end, Groups);
sort_groups(Groups, desc, bytes) -> lists:sort(fun({_, {_,A}}, {_, {_,B}}) -> A >= B end, Groups);
sort_groups(Groups, asc, bytes)  -> lists:sort(fun({_, {_,A}}, {_, {_,B}}) -> A =< B end, Groups).

inc_stats(Key, Bytes, Map) ->
    case maps:get(Key, Map, nil) of
        nil -> Map#{Key => {1, Bytes}};
        {C, B} -> Map#{Key => {C + 1, B + Bytes}}
    end.

fmt_bytes(B) when B >= 1048576 -> lists:flatten(io_lib:format("~.1f MB", [B / 1048576]));
fmt_bytes(B) when B >= 1024 -> lists:flatten(io_lib:format("~.1f KB", [B / 1024]));
fmt_bytes(B) -> integer_to_list(B) ++ " B".

%%%% Display %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

show_detail(Frames, Cfg, LT, Total) ->
    io:format("link_type: ~B  packets: ~B~n", [LT, Total]),
    Fields = get_in(Cfg, [display, fields], []),
    case Fields of
        [] ->
            Indexed = lists:zip(lists:seq(0, max(length(Frames) - 1, 0)), Frames),
            [begin
                io:format("===== ~w =====~n", [I]),
                [display_layer(L) || L <- F]
            end || {I, {_S, F}} <- Indexed];
        _ ->
            io:format("~n"),
            Indexed = lists:zip(lists:seq(0, max(length(Frames) - 1, 0)), Frames),
            [io:format("  ~4w  ~s~n", [I, compact_line(F, Fields)]) || {I, {_S, F}} <- Indexed]
    end.

display_layer(L) ->
    Proto = maps:get(proto, L),
    io:format("  --~s--~n", [proto_name(Proto)]),
    Order = field_order(Proto),
    [io:format("    ~-12s ~s~n", [atom_to_list(K), fmt_val(maps:get(K, L, ""))])
     || K <- Order, maps:is_key(K, L)].

compact_line(Frame, Fields) ->
    Vals = [fmt_val(find_field(Frame, F, "-")) || F <- Fields],
    string:join(Vals, "  ").

%%%% Utils %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

frame_summary(Stack) ->
    Names = [proto_name(maps:get(proto, L)) || L <- Stack],
    S = string:join(Names, "/"),
    Last = lists:last(Stack),
    S1 = case maps:get(src_port, Last, nil) of
        nil -> S;
        SP -> S ++ " " ++ integer_to_list(SP) ++ ">" ++ integer_to_list(maps:get(dst_port, Last, 0))
    end,
    case maps:get(opcode, Last, nil) of
        nil -> S1;
        Op -> S1 ++ " " ++ atom_to_list(Op)
    end.

%% find_field/3 with default
find_field([], _Field, Def) -> Def;
find_field([L | Rest], Field, Def) ->
    case maps:is_key(Field, L) of
        true -> maps:get(Field, L);
        _ -> find_field(Rest, Field, Def)
    end.

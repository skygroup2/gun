-module(gun_socks5_msg).
-author("subhuti").

%% API
-export([
  encode/2,
  decode/2,
  recv_size/1
]).

%% METHOD
%%  00 -> NO AUTHENTICATION
%%  02 -> USERNAME/PASSWORD

%% CMD
%%  01 : CONNECT
%%  02 : BIND
%%  03 : UDP ASSOCIATE

recv_size(connect) -> 4;
recv_size(reply) -> 4;
recv_size(auth_status) -> 2;
recv_size(auth_data) -> 3;
recv_size(auth) -> 3;
recv_size(auth_resp) -> 2.

encode(c, #{type := connect, host := Host, port := Port}) ->
  AddrBin = encode_addr(Host, Port),
  <<5, 1, 0, AddrBin/binary>>;
encode(c, #{type := auth_data, user := User, password := Password}) ->
  UL = byte_size(User),
  PL = byte_size(Password),
  <<1, UL, User/binary, PL, Password/binary>>;
encode(c, #{type := auth, method := Method}) ->
  MethodBin = if
    is_list(Method) -> iolist_to_binary(Method);
    true -> <<Method>>
  end,
  MethodSize = byte_size(MethodBin),
  <<5, MethodSize, MethodBin/binary>>;
encode(s, #{type := reply, reply := Rep, reserve := Rev, host := Host, port := Port}) ->
  AddrBin = encode_addr(Host, Port),
  <<5, Rep, Rev, AddrBin/binary>>;
encode(s, #{type := auth_status, status := Status}) ->
  <<1, Status>>;
encode(s, #{type := auth_resp, method := Method}) ->
  <<5, Method>>.


decode(s, <<5, 1, 0, AType, AddrBin/binary>>) ->
  case decode_addr(AType, AddrBin) of
    {ok, Host, Port} ->
      #{type => connect, host => Host, port => Port};
    Error ->
      Error
  end;
decode(c, <<5, Rep, Rev, AType, AddrBin/binary>>) ->
  case decode_addr(AType, AddrBin) of
    {ok, Host, Port} ->
      #{type => reply, reply => Rep, reserve => Rev, host => Host, port => Port};
    Error ->
      Error
  end;
decode(s, <<1, UL, User:UL/binary, PL, Password:PL/binary>>) ->
  #{type => auth_data, user => User, password => Password};
decode(s, <<1, UL, SmallSize>>) when byte_size(SmallSize) < UL + 1 ->
  {more, UL + 1 - byte_size(SmallSize)};
decode(s, <<1, UL, _:UL/binary, PL, SmallSize>>) when byte_size(SmallSize) < PL ->
  {more, PL - byte_size(SmallSize)};
decode(s, <<5, _MethodSize, MethodBin/binary>>) ->
  #{type => auth, method => binary_to_list(MethodBin)};
decode(c, <<1, Status>>) ->
  #{type => auth_status, status => Status};
decode(c, <<5, Method>>) ->
  #{type => auth_resp, method => Method};
decode(_, _) ->
  {error, socks_msg}.


encode_addr({IP1, IP2, IP3, IP4}, Port) ->
  << 1, IP1, IP2, IP3, IP4, Port:16 >>;
encode_addr({IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}, Port) ->
  << 4, IP1:16, IP2:16, IP3:16, IP4:16, IP5:16, IP6:16, IP7:16, IP8:16, Port:16 >>;
encode_addr(HostName, Port) when is_list(HostName) ->
  encode_addr(iolist_to_binary(HostName), Port);
encode_addr(HostName, Port) ->
  HL = byte_size(HostName),
  << 3, HL, HostName/binary, Port:16 >>.

decode_addr(1, <<IP1, IP2, IP3, IP4, Port:16 >>) -> % IPv4
  {ok, {IP1, IP2, IP3, IP4}, Port};
decode_addr(4, <<IP1:16, IP2:16, IP3:16, IP4:16, IP5:16, IP6:16, IP7:16, IP8:16, Port:16>>) -> % IPv6
  {ok, {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}, Port};
decode_addr(3, <<HL, HostName:HL/binary, Port:16>>) -> % Domain
  {ok, binary_to_list(HostName), Port};
decode_addr(1, SmallBin) when byte_size(SmallBin) < 6 ->
  {more, 6 - byte_size(SmallBin)};
decode_addr(4, SmallBin) when byte_size(SmallBin) < 18 ->
  {more, 18 - byte_size(SmallBin)};
decode_addr(3, <<HL, SmallBin/binary>>) when byte_size(SmallBin) < HL + 2 ->
  {more, HL + 2 - byte_size(SmallBin)};
decode_addr(_AType, _) -> {error, socks_addr}.



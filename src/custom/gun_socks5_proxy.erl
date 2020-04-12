-module(gun_socks5_proxy).

-export([
  name/0,
  connect/4
]).

name() -> socks5_proxy.

connect(Host, Port, Opts, Timeout) when is_list(Host), is_integer(Port), (Timeout =:= infinity orelse is_integer(Timeout)) ->
  %% get the proxy host and port from the options
  ProxyHost = proplists:get_value(socks5_host, Opts),
  ProxyPort = proplists:get_value(socks5_port, Opts),

  %% filter connection options
  AcceptedOpts =  [linger, nodelay, send_timeout, send_timeout_close, raw, inet6, ip],
  BaseOpts = [binary, {active, false}, {packet, 0}, {keepalive,  true}, {nodelay, true}],
  TransOpts= proplists:get_value(tcp_opt, Opts, []),
  ConnectOpts = gun_util:filter_options(TransOpts, AcceptedOpts, BaseOpts),

  %% connect to the socks 5 proxy
  case gen_tcp:connect(ProxyHost, ProxyPort, ConnectOpts, Timeout) of
    {ok, Socket} ->
      case do_handshake(Socket, Host, Port, Opts, Timeout) of
        ok ->
          {ok, Socket};
        Error ->
          gen_tcp:close(Socket),
          Error
      end;
    Error ->
      Error
  end.

%% private functions
do_handshake(Socket, Host, Port, Options, Timeout) ->
  ProxyUser = proplists:get_value(socks5_user, Options),
  ProxyPass = proplists:get_value(socks5_pass, Options, <<>>),
  case ProxyUser of
    undefined ->
      %% no auth
      ok = gen_tcp:send(Socket, << 5, 1, 0 >>),
      case gen_tcp:recv(Socket, 2, Timeout) of
        {ok, << 5, 0 >>} ->
          do_connection(Socket, Host, Port, Options, Timeout);
        {ok, _Reply} ->
          {error, unknown_reply};
        Error ->
          Error
      end;
    _ ->
      case do_authentication(Socket, ProxyUser, ProxyPass, Timeout) of
        ok ->
          do_connection(Socket, Host, Port, Options, Timeout);
        Error ->
          Error
      end
  end.

do_authentication(Socket, User, Pass, Timeout) ->
  ok = gen_tcp:send(Socket, << 5, 1, 2 >>),
  case gen_tcp:recv(Socket, 2, Timeout) of
    {ok, <<5, 0>>} ->
      ok;
    {ok, <<5, 2>>} ->
      UserLength = byte_size(User),
      PassLength = byte_size(Pass),
      Msg = iolist_to_binary([<< 1, UserLength >>,
        User, << PassLength >>,
        Pass]),
      ok = gen_tcp:send(Socket, Msg),
      case gen_tcp:recv(Socket, 2, Timeout) of
        {ok, <<1, 0>>} ->
          ok;
        {ok, _} ->
          {error, not_authenticated};
        {error, Reason} ->
          {error, Reason}
      end;
    {ok, _} ->
      {error, not_authenticated};
    {error, Reason} ->
      {error, Reason}
  end.


do_connection(Socket, Host, Port, Options, Timeout) ->
  Resolve = proplists:get_value(socks5_resolve, Options, remote),
  case addr(Host, Port, Resolve) of
    Addr when is_binary(Addr) ->
      ok = gen_tcp:send(Socket, << 5, 1, 0, Addr/binary >>),
      case gen_tcp:recv(Socket, 4, Timeout) of
        {ok, << 5, 0, 0, AType>>} ->
          BoundAddr = recv_addr_port(AType, gen_tcp, Socket, Timeout),
          check_connection(BoundAddr);
        {ok, _} ->
          {error, badarg};
        Error ->
          Error
      end;
    Error ->
      Error
  end.

addr(Host, Port, Resolve) ->
  case inet_parse:address(Host) of
    {ok, {IP1, IP2, IP3, IP4}} ->
      << 1, IP1, IP2, IP3, IP4, Port:16 >>;
    {ok, {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}} ->
      << 4, IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8, Port:16 >>;
    _ -> %% domain name
      case Resolve of
        local ->
          case inet:getaddr(Host, inet) of
            {ok, {IP1, IP2, IP3, IP4}} ->
              << 1, IP1, IP2, IP3, IP4, Port:16 >>;
            Error ->
              case inet:getaddr(Host, inet6) of
                {ok, {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}} ->
                  << 4, IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8, Port:16 >>;
                _ ->
                  Error
              end
          end;
        _Remote ->
          Host1 = list_to_binary(Host),
          HostLength = byte_size(Host1),
          << 3, HostLength, Host1/binary, Port:16 >>
      end
  end.

recv_addr_port(1 = AType, Transport, Socket, Timeout) -> % IPv4
   {ok, Data} = Transport:recv(Socket, 6, Timeout),
   <<AType, Data/binary>>;
recv_addr_port(4 = AType, Transport, Socket, Timeout) -> % IPv6
   {ok, Data} = Transport:recv(Socket, 18, Timeout),
   <<AType, Data/binary>>;
recv_addr_port(3 = AType, Transport, Socket, Timeout) -> % Domain
   {ok, <<DLen/integer>>} = Transport:recv(Socket, 1, Timeout),
   {ok, AddrPort} = Transport:recv(Socket, DLen + 2, Timeout),
   <<AType, DLen, AddrPort/binary>>;
recv_addr_port(_, _, _, _) ->
   error.

check_connection(<< 3, _DomainLen:8, _Domain/binary >>) ->
  ok;
check_connection(<< 1, _Addr:32, _Port:16 >>) ->
  ok;
check_connection(<< 4, _Addr:128, _Port:16 >>) ->
  ok;
check_connection(_) ->
  {error, no_connection}.

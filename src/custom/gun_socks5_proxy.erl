-module(gun_socks5_proxy).

-export([
  connect/3,
  connect/4,
  recv/2,
  recv/3,
  send/2,
  setopts/2,
  controlling_process/2,
  peername/1,
  close/1,
  shutdown/2,
  sockname/1]).

-type socks5_socket() :: {atom(), inet:socket()}.
-export_type([socks5_socket/0]).

ssl_opts(Host, Opts) ->
  [{server_name_indication, Host} | gun_util:ssl_opts(Host,Opts)].

connect(Host, Port, Opts) ->
  connect(Host, Port, Opts, 35000).


connect(Host, Port, Opts, Timeout) when is_list(Host), is_integer(Port),
                                        (Timeout =:= infinity orelse is_integer(Timeout)) ->
  %% get the proxy host and port from the options
  ProxyHost = proplists:get_value(socks5_host, Opts),
  ProxyPort = proplists:get_value(socks5_port, Opts),
  Transport = proplists:get_value(socks5_transport, Opts),

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
          case Transport of
            gun_tls ->
              SSLOpts = ssl_opts(Host, Opts),
              %% upgrade the tcp connection
              case ssl:connect(Socket, SSLOpts, Timeout) of
                {ok, SslSocket} ->
                  {ok, {Transport, SslSocket}};
                Error ->
                  gen_tcp:close(Socket),
                  Error
              end;
            _ ->
              {ok, {Transport, Socket}}
          end;
        Error ->
          gen_tcp:close(Socket),
          Error
      end;
    Error ->
      Error
  end.


recv(Socket, Length) ->
  recv(Socket, Length, infinity).

%% @doc Receive a packet from a socket in passive mode.
%% @see gen_tcp:recv/3
-spec recv(socks5_socket(), non_neg_integer(), timeout())
    -> {ok, any()} | {error, closed | atom()}.
recv({Transport, Socket}, Length, Timeout) ->
  Transport:recv(Socket, Length, Timeout).


%% @doc Send a packet on a socket.
%% @see gen_tcp:send/2
-spec send(socks5_socket(), iolist()) -> ok | {error, atom()}.
send({Transport, Socket}, Packet) ->
  Transport:send(Socket, Packet).

%% @doc Set one or more options for a socket.
%% @see inet:setopts/2
-spec setopts(socks5_socket(), list()) -> ok | {error, atom()}.
setopts({Transport, Socket}, Opts) ->
  Transport:setopts(Socket, Opts).

%% @doc Assign a new controlling process <em>Pid</em> to <em>Socket</em>.
%% @see gen_tcp:controlling_process/2
-spec controlling_process(socks5_socket(), pid())
    -> ok | {error, closed | not_owner | atom()}.
controlling_process({Transport, Socket}, Pid) ->
  Transport:controlling_process(Socket, Pid).

%% @doc Return the address and port for the other end of a connection.
%% @see inet:peername/1
-spec peername(socks5_socket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
peername({Transport, Socket}) ->
  Transport:peername(Socket).

%% @doc Close a socks5 socket.
%% @see gen_tcp:close/1
-spec close(socks5_socket()) -> ok.
close({Transport, Socket}) ->
  Transport:close(Socket).

%% @doc Immediately close a socket in one or two directions.
%% @see gen_tcp:shutdown/2
-spec shutdown(socks5_socket(), read | write | read_write) -> ok.
shutdown({Transport, Socket}, How) ->
  Transport:shutdown(Socket, How).

%% @doc Get the local address and port of a socket
%% @see inet:sockname/1
-spec sockname(socks5_socket())
    -> {ok, {inet:ip_address(), inet:port_number()}} | {error, atom()}.
sockname({Transport, Socket}) ->
  Transport:sockname(Socket).

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

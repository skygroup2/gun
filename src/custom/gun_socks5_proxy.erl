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
    _ when ProxyUser == undefined orelse ProxyUser == nil ->
      %% no auth
      ok = gen_tcp:send(Socket, gun_socks5_msg:encode(c, #{type => auth, method => 0})),
      case recv_msg(Socket, gun_socks5_msg:recv_size(auth_resp), Timeout, <<>>) of
        #{type := auth_resp, method := 0} ->
          do_connection(Socket, Host, Port, Options, Timeout);
        #{} = Reply ->
          {error, {proxy_error, Reply}};
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
  ok = gen_tcp:send(Socket, gun_socks5_msg:encode(c, #{type => auth, method => 2})),
  case recv_msg(Socket, gun_socks5_msg:recv_size(auth_resp), Timeout, <<>>) of
    #{type := auth_resp, method := 0} ->
      ok;
    #{type := auth_resp, method := 2} ->
      ok = gen_tcp:send(Socket, gun_socks5_msg:encode(c, #{type => auth_data, user => User, password => Pass})),
      case recv_msg(Socket, gun_socks5_msg:recv_size(auth_status), Timeout, <<>>) of
        #{type := auth_status, status := 0} ->
          ok;
        #{type := auth_status, status := Status} ->
          {error, {proxy_error, Status}};
        {error, Reason} ->
          {error, Reason}
      end;
    #{} = Reply ->
      {error, {proxy_error, Reply}};
    {error, Reason} ->
      {error, Reason}
  end.


do_connection(Socket, Host, Port, Options, Timeout) ->
  Resolve = proplists:get_value(socks5_resolve, Options, remote),
  case resolve_addr(Host, Resolve) of
    {error, Reason} ->
      {error, Reason};
    Addr ->
      ok = gen_tcp:send(Socket, gun_socks5_msg:encode(c, #{type => connect, host => Addr, port => Port})),
      case recv_msg(Socket, gun_socks5_msg:recv_size(reply), Timeout, <<>>) of
        #{type := reply} ->
          ok;
        #{} = Reply ->
          {error, {proxy_error, Reply}};
        Error ->
          Error
      end
  end.

resolve_addr(Host, Resolve) ->
  case inet_parse:address(Host) of
    {ok, {IP1, IP2, IP3, IP4}} ->
      {IP1, IP2, IP3, IP4};
    {ok, {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}} ->
      {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8};
    {error, _} -> %% domain name
      case Resolve of
        local ->
          case inet:getaddr(Host, inet) of
            {ok, {IP1, IP2, IP3, IP4}} ->
              {IP1, IP2, IP3, IP4};
            Error ->
              case inet:getaddr(Host, inet6) of
                {ok, {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8}} ->
                  {IP1, IP2, IP3, IP4, IP5, IP6, IP7, IP8};
                _ ->
                  Error
              end
          end;
        _Remote ->
          list_to_binary(Host)
      end
  end.

recv_msg(Socket, Length, Timeout, Buf) ->
  case gen_tcp:recv(Socket, Length, Timeout) of
    {ok, NewBin} ->
      NewBuf = <<Buf/binary, NewBin/binary>>,
      case gun_socks5_msg:decode(c, NewBuf) of
        {more, MoreLen} ->
          recv_msg(Socket, MoreLen, Timeout, NewBuf);
        Msg ->
          Msg
      end;
    {error, Reason} ->
      {error, Reason}
  end.

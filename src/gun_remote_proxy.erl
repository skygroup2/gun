%%%-------------------------------------------------------------------
%%% @author MrR
%%% @copyright (C) 2018, GSKYNET
%%% @doc
%%%
%%% @end
%%% Created : 31. Oct 2018 4:01 PM
%%%-------------------------------------------------------------------
-module(gun_remote_proxy).

-export([messages/1,
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

-define(TIMEOUT, 30000).

-type socks5_socket() :: {atom(), inet:socket()}.
-export_type([socks5_socket/0]).

-ifdef(no_proxy_sni_support).

ssl_opts(Host, Opts) ->
  hackney_connect:ssl_opts(Host, Opts).

-else.

ssl_opts(Host, Opts) ->
  [{server_name_indication, Host} | hackney_connect:ssl_opts(Host,Opts)].

-endif.

%% @doc Atoms used to identify messages in {active, once | true} mode.
messages({hackney_ssl, _}) ->
  {ssl, ssl_closed, ssl_error};
messages({_, _}) ->
  {tcp, tcp_closed, tcp_error}.


connect(Host, Port, Opts) ->
  connect(Host, Port, Opts, 35000).


connect(Host, Port, Opts, Timeout) when is_list(Host), is_integer(Port),
                                        (Timeout =:= infinity orelse is_integer(Timeout)) ->
  %% get the proxy host and port from the options
  ProxyHost = proplists:get_value(remote_host, Opts),
  ProxyPort = proplists:get_value(remote_port, Opts),
  Transport = proplists:get_value(remote_transport, Opts),

  %% filter connection options
  AcceptedOpts =  [linger, nodelay, send_timeout,
    send_timeout_close, raw, inet6, ip],
  BaseOpts = [binary, {active, false}, {packet, 0}, {keepalive,  true},
    {nodelay, true}],
  ConnectOpts = gun_util:filter_options(Opts, AcceptedOpts, BaseOpts),

  %% connect to the socks 5 proxy
  case gen_tcp:connect(ProxyHost, ProxyPort, ConnectOpts, Timeout) of
    {ok, Socket} ->
      case do_handshake(Socket, Host, Port, Opts) of
        ok ->
          case Transport of
            hackney_ssl ->
              SSLOpts = ssl_opts(Host, Opts),
              %% upgrade the tcp connection
              case ssl:connect(Socket, SSLOpts) of
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

%% message format
%% REQ
%% 1 => Host, 2 => HostName, 3 => Port, 4 => Timeout, 5 => ProxyType, 6 => ProxyHost, 7 => ProxyHostName, 8 => ProxyPort
%% 9 => User, 10 -> Password

%% ACK (2 bytes == error code)

encode_msg(Opts) ->
  M =
    lists:foldl(fun(X, Acc) ->
      case X of
        {host, {A, B, C, D}} ->
          <<Acc/binary, 1, 4, A, B, C, D>>;
        {host, HostName} ->
          StrB = erlang:iolist_to_binary(HostName),
          <<Acc/binary, 2, (byte_size(StrB)), StrB/binary>>;
        {port, Port} ->
          <<Acc/binary, 3, Port:16>>;
        {timeout, Timeout} ->
          <<Acc/binary, 4, Timeout:16>>;
        {type, socks5} ->
          <<Acc/binary, 5, "socks5">>;
        {type, http} ->
          <<Acc/binary, 5, "http">>;
        {proxy_host, {A, B, C, D}} ->
          <<Acc/binary, 6, 4, A, B, C, D>>;
        {proxy_host, HostName} ->
          StrB = erlang:iolist_to_binary(HostName),
          <<Acc/binary, 7, (byte_size(StrB)), StrB/binary>>;
        {proxy_port, Port} ->
          <<Acc/binary, 8, Port:16>>;
        {proxy_user, ProxyUser} ->
          StrB = erlang:iolist_to_binary(ProxyUser),
          <<Acc/binary, 9, (byte_size(StrB)), StrB/binary>>;
        {proxy_pass, ProxyPass} ->
          StrB = erlang:iolist_to_binary(ProxyPass),
          <<Acc/binary, 10, (byte_size(StrB)), StrB/binary>>;
        {proxy_ip, {A, B, C, D}} ->
          <<Acc/binary, 11, 4, A, B, C, D>>;
        {proxy_ip, _} ->
          Acc
      end
    end, <<>>, Opts),
  <<(byte_size(M)):16, M/binary>>.

%% private functions
do_handshake(Socket, Host, Port, Options) ->
  RemoteProxy = proplists:get_value(remote_proxy, Options, []),
  ProxyIP = proplists:get_value(proxy_ip, RemoteProxy),
  Msg1 =
    case proplists:get_value(proxy, RemoteProxy) of
      {socks5, ProxyHost, ProxyPort} ->
        Resolve = proplists:get_value(socks5_resolve, RemoteProxy, remote),
        case addr(Host, Resolve) of
          {ok, Host1} ->
            [{host, Host1}, {port, Port}, {proxy_ip, ProxyIP}, {timeout, 35000}, {type, socks5}, {proxy_host, ProxyHost}, {proxy_port, ProxyPort}];
          _ ->
            [{type, error}]
        end;
      {ProxyHost, ProxyPort} ->
        [{host, Host}, {port, Port}, {proxy_ip, ProxyIP}, {timeout, 35000}, {type, http}, {proxy_host, ProxyHost}, {proxy_port, ProxyPort}];
      Url when is_binary(Url) orelse is_list(Url) ->
        Url1 = gun_url:parse_url(Url),
        #{host := ProxyHost, port := ProxyPort} = gun_url:normalize(Url1),
        [{host, Host}, {port, Port}, {proxy_ip, ProxyIP}, {timeout, 35000}, {type, http}, {proxy_host, ProxyHost}, {proxy_port, ProxyPort}];
      undefined ->
        [{host, Host}, {port, Port}, {proxy_ip, ProxyIP}, {timeout, 35000}]
    end,
  Msg2 =
    case proplists:get_value(proxy_auth, RemoteProxy) of
      {ProxyUser, ProxyPass} ->
        Msg1 ++ [{proxy_user, ProxyUser}, {proxy_pass, ProxyPass}];
      _ ->
        Msg1
    end,
  ok = gen_tcp:send(Socket, encode_msg(Msg2)),
  case gen_tcp:recv(Socket, 2, ?TIMEOUT) of
    {ok, << 0, 0 >>} ->
      ok;
    {ok, _Reply} ->
      {error, unknown_reply};
    Error ->
      Error
  end.

addr(Host, _Resolve) when is_tuple(Host) andalso (tuple_size(Host) == 4 orelse tuple_size(Host) == 8) ->
  {ok, Host};
addr(Host, Resolve) ->
  case inet_parse:address(Host) of
    {ok, X} ->
      {ok, X};
    _ -> %% domain name
      case Resolve of
        local ->
          case inet:getaddr(Host, inet) of
            {ok, X} ->
              {ok, X};
            Error ->
              case inet:getaddr(Host, inet6) of
                {ok, X} ->
                  {ok, X};
                _ ->
                  Error
              end
          end;
        _Remote ->
          {ok, Host}
      end
  end.

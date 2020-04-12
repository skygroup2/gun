-module(gun_http_proxy).

-export([
  name/0,
  connect/4
]).

name() -> http_proxy.

connect(ProxyHost, ProxyPort, Opts, Timeout)
  when is_list(ProxyHost), is_integer(ProxyPort), (Timeout =:= infinity orelse is_integer(Timeout)) ->
  %% get the  host and port to connect from the options
  Host = proplists:get_value(connect_host, Opts),
  Port = proplists:get_value(connect_port, Opts),
  %% filter connection options
  AcceptedOpts =  [linger, nodelay, send_timeout, send_timeout_close, raw, inet6, ip],
  BaseOpts = [binary, {active, false}, {packet, 0}, {keepalive,  true}, {nodelay, true}],
  TransOpts= proplists:get_value(tcp_opt, Opts, []),
  ConnectOpts = gun_util:filter_options(TransOpts, AcceptedOpts, BaseOpts),

  %% connnect to the proxy, and upgrade the socket if needed.
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
  ProxyUser = proplists:get_value(connect_user, Options),
  ProxyPass = proplists:get_value(connect_pass, Options, <<>>),
  ProxyPort = proplists:get_value(connect_port, Options),
  %% set defaults headers
  HostHdr = case ProxyPort of
    80 ->
      list_to_binary(Host);
    _ ->
      iolist_to_binary([Host, ":", integer_to_list(ProxyPort)])
  end,
  UA =  <<"gun/1.3.2">>,
  Headers0 = [<<"Host: ", HostHdr/binary>>, <<"User-Agent: ", UA/binary >>],
  Headers = case ProxyUser of
    undefined ->
      Headers0;
    _ ->
      Credentials = base64:encode(<<ProxyUser/binary, ":",
        ProxyPass/binary>>),
      Headers0 ++ [<< "Proxy-Authorization: Basic ", Credentials/binary >>]
  end,
  Path = iolist_to_binary([Host, ":", integer_to_list(Port)]),

  Payload = [<< "CONNECT ", Path/binary, " HTTP/1.1", "\r\n" >>,
    gun_bstr:join(lists:reverse(Headers), <<"\r\n">>),
    <<"\r\n\r\n">>],
  case gen_tcp:send(Socket, Payload) of
    ok ->
      check_response(Socket, Timeout);
    Error ->
      Error
  end.

check_response(Socket, Timeout) ->
  case gen_tcp:recv(Socket, 0, Timeout) of
    {ok, Data} ->
      {_Version, Status, _Msg, Rest} = cow_http:parse_status_line(Data),
      if
        Status == 200 orelse Status == 201 ->
          {Headers, _} = cow_http:parse_headers(Rest),
          update_proxy_ip([<<"x-hola-ip">>], Headers);
        true ->
          {error, {proxy_error, Status}}
      end;
    Error ->
      Error
  end.

update_proxy_ip([], _Headers) ->
  ok;

update_proxy_ip([Name|Remain], Headers) ->
  case lists:keyfind(Name, 1, Headers) of
    {_, Addr} ->
      put(x_hola_ip, Addr),
      ok;
    false ->
      update_proxy_ip(Remain, Headers)
  end.

-module(gun_test).
%% API
-export([test/1]).


proxy_opt(O) ->
  case O of
    0 ->
      #{retry => 2};
    1 ->
      #{retry => 2, proxy => {socks5, {127, 0, 0, 1}, 1080}};
    2 ->
      #{retry => 2, proxy => "http://gb.smartproxy.io:30001", proxy_auth => {<<"dev2019">>, <<"DEV2019#skn">>}, insecure => true};
    _ ->
      #{retry => 2, proxy => "http://customer-federico-session-357.zproxy.lum-superproxy.io:22225", proxy_auth => {<<"lum-customer-federico-zone-msm-country-ca-session-glob_rand3838550">>, <<"o600xs0at7z6">>}, insecure => true}
  end.

test(V) ->
  application:ensure_all_started(gun),
  {ok, ConnPid} = gun:open("lumtest.com", 80, proxy_opt(V)),
  io:format("Connection ~p~n",[ConnPid]),
  {ok, Protocol} = gun:await_up(ConnPid),
  io:format("Protocol ~p~n",[Protocol]),
  StreamRef = gun:get(ConnPid, "/myip"),
  print_body(ConnPid, StreamRef),
  gun:shutdown(ConnPid),
  ConnPid.

print_body(ConnPid, StreamRef) ->
  receive
    {gun_response, ConnPid, StreamRef, fin, Status, Headers} ->
      io:format("No data ~p / ~p ~n",[Status, Headers]),
      no_data;
    {gun_response, ConnPid, StreamRef, nofin, Status, Headers} ->
      io:format("Data ~p / ~p ~n",[Status, Headers]),
      receive_data(ConnPid, StreamRef, StreamRef);
    {'DOWN', StreamRef, process, ConnPid, Reason} ->
      error_logger:error_msg("Oops!"),
      exit(Reason)
  after 5000 ->
    exit(timeout)
  end.

receive_data(ConnPid, MRef, StreamRef) ->
  receive
    {gun_data, ConnPid, StreamRef, nofin, Data} ->
        io:format("~s~n", [Data]),
        receive_data(ConnPid, MRef, StreamRef);
    {gun_data, ConnPid, StreamRef, fin, Data} ->
        io:format("~s~n", [Data]);
    {'DOWN', MRef, process, ConnPid, Reason} ->
        error_logger:error_msg("Oops!"),
        exit(Reason)
  after 5000 ->
    exit(timeout)
  end.
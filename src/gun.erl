%% Copyright (c) 2013-2018, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(gun).

-ifdef(OTP_RELEASE).
-compile({nowarn_deprecated_function, [{erlang, get_stacktrace, 0}]}).
-endif.

%% Connection.
-export([open/2]).
-export([open/3]).
-export([open_unix/2]).
-export([info/1]).
-export([close/1]).
-export([shutdown/1]).

%% Requests.
-export([delete/2]).
-export([delete/3]).
-export([delete/4]).
-export([get/2]).
-export([get/3]).
-export([get/4]).
-export([head/2]).
-export([head/3]).
-export([head/4]).
-export([options/2]).
-export([options/3]).
-export([options/4]).
-export([patch/3]).
-export([patch/4]).
-export([patch/5]).
-export([post/3]).
-export([post/4]).
-export([post/5]).
-export([put/3]).
-export([put/4]).
-export([put/5]).
-export([request/4]).
-export([request/5]).
-export([request/6]).

%% Streaming data.
-export([data/4]).

%% Tunneling.
-export([connect/2]).
-export([connect/3]).
-export([connect/4]).

%% Awaiting gun messages.
-export([await/2]).
-export([await/3]).
-export([await/4]).
-export([await_body/2]).
-export([await_body/3]).
-export([await_body/4]).
-export([await_up/1]).
-export([await_up/2]).
-export([await_up/3]).

%% Flushing gun messages.
-export([flush/1]).

%% Cancelling a stream.
-export([cancel/2]).

%% Websocket.
-export([ws_upgrade/2]).
-export([ws_upgrade/3]).
-export([ws_upgrade/4]).
-export([ws_send/2]).

%% Internals.
-export([start_link/4]).
-export([proc_lib_hack/5]).
-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).

-type headers() :: [{binary(), iodata()}].

-type ws_close_code() :: 1000..4999.
-type ws_frame() :: close | ping | pong
| {text | binary | close | ping | pong, iodata()}
| {close, ws_close_code(), iodata()}.

-type opts() :: #{
connect_timeout => timeout(),
http_opts => http_opts(),
http2_opts => http2_opts(),
protocols => [http | http2],
retry => non_neg_integer(),
retry_timeout => pos_integer(),
trace => boolean(),
transport => tcp | tls | ssl,
transport_opts => [gen_tcp:connect_option()] | [ssl:connect_option()],
ws_opts => ws_opts()
}.
-export_type([opts/0]).
%% @todo Add an option to disable/enable the notowner behavior.

-type connect_destination() :: #{
host := inet:hostname() | inet:ip_address(),
port := inet:port_number(),
username => iodata(),
password => iodata(),
protocol => http | http2, %% @todo Remove in Gun 2.0.
protocols => [http | http2],
transport => tcp | tls,
tls_opts => [ssl:connect_option()],
tls_handshake_timeout => timeout()
}.
-export_type([connect_destination/0]).

-type intermediary() :: #{
type := connect,
host := inet:hostname() | inet:ip_address(),
port := inet:port_number(),
transport := tcp | tls,
protocol := http | http2
}.

%% @todo When/if HTTP/2 CONNECT gets implemented, we will want an option here
%% to indicate that the request must be sent on an existing CONNECT stream.
%% This is of course not required for HTTP/1.1 since the CONNECT takes over
%% the entire connection.
-type req_opts() :: #{
reply_to => pid()
}.
-export_type([req_opts/0]).

-type http_opts() :: #{
keepalive => timeout(),
transform_header_name => fun((binary()) -> binary()),
version => 'HTTP/1.1' | 'HTTP/1.0'
}.
-export_type([http_opts/0]).

-type http2_opts() :: #{
keepalive => timeout()
}.
-export_type([http2_opts/0]).

%% @todo keepalive
-type ws_opts() :: #{
compress => boolean(),
protocols => [{binary(), module()}]
}.
-export_type([ws_opts/0]).

-record(state, {
  parent :: pid(),
  owner :: pid(),
  owner_ref :: reference(),
  host :: inet:hostname() | inet:ip_address(),
  port :: inet:port_number(),
  origin_host :: inet:hostname() | inet:ip_address(),
  origin_port :: inet:port_number(),
  intermediaries = [] :: [intermediary()],
  opts :: opts(),
  keepalive_ref :: undefined | reference(),
  socket :: undefined | inet:socket() | ssl:sslsocket(),
  transport :: module(),
  % PATCH BEGIN
  socket_t :: tuple(),
  proxy_handle :: module(),
  proxy_opt = [],
  % PATCH END
  protocol :: module(),
  protocol_state :: any(),
  last_error :: any()
}).

%% Connection.

-spec open(inet:hostname() | inet:ip_address(), inet:port_number())
      -> {ok, pid()} | {error, any()}.
open(Host, Port) ->
  open(Host, Port, #{}).

-spec open(inet:hostname() | inet:ip_address(), inet:port_number(), opts())
      -> {ok, pid()} | {error, any()}.
open(Host, Port, Opts) when is_binary(Host) ->
  do_open(binary_to_list(Host), Port, Opts);
open(Host, Port, Opts) when is_list(Host); is_atom(Host); is_tuple(Host) ->
  do_open(Host, Port, Opts).

-spec open_unix(Path :: string(), opts())
      -> {ok, pid()} | {error, any()}.
open_unix(SocketPath, Opts) ->
  do_open({local, SocketPath}, 0, Opts).

do_open(Host, Port, Opts0) ->
  %% We accept both ssl and tls but only use tls in the code.
  Opts = case Opts0 of
           #{transport := ssl} -> Opts0#{transport => tls};
           _ -> Opts0
         end,
  case check_options(maps:to_list(Opts)) of
    ok ->
      case supervisor:start_child(gun_sup, [self(), Host, Port, Opts]) of
        OK = {ok, ServerPid} ->
          consider_tracing(ServerPid, Opts),
          OK;
        StartError ->
          StartError
      end;
    CheckError ->
      CheckError
  end.

check_options([]) ->
  ok;
check_options([{proxy, Proxy} | Opts]) when is_list(Proxy) orelse is_binary(Proxy) orelse is_tuple(Proxy) ->
  check_options(Opts);
check_options([{proxy_auth, ProxyAuth} | Opts]) when is_tuple(ProxyAuth) orelse ProxyAuth == nil ->
  check_options(Opts);
check_options([{socks5_resolve, Resolve} | Opts]) when is_atom(Resolve) ->
  check_options(Opts);
check_options([{recv_timeout, T} | Opts]) when is_integer(T), T >= 0 ->
  check_options(Opts);
check_options([{insecure, Insecure} | Opts]) when is_boolean(Insecure) ->
  check_options(Opts);
check_options([{connect_timeout, infinity} | Opts]) ->
  check_options(Opts);
check_options([{connect_timeout, T} | Opts]) when is_integer(T), T >= 0 ->
  check_options(Opts);
check_options([{http_opts, ProtoOpts} | Opts]) when is_map(ProtoOpts) ->
  case gun_http:check_options(ProtoOpts) of
    ok ->
      check_options(Opts);
    Error ->
      Error
  end;
check_options([{http2_opts, ProtoOpts} | Opts]) when is_map(ProtoOpts) ->
  case gun_http2:check_options(ProtoOpts) of
    ok ->
      check_options(Opts);
    Error ->
      Error
  end;
check_options([Opt = {protocols, L} | Opts]) when is_list(L) ->
  Len = length(L),
  case length(lists:usort(L)) of
    Len when Len > 0 ->
      Check = lists:usort([(P =:= http) orelse (P =:= http2) || P <- L]),
      case Check of
        [true] ->
          check_options(Opts);
        _ ->
          {error, {options, Opt}}
      end;
    _ ->
      {error, {options, Opt}}
  end;
check_options([{retry, R} | Opts]) when is_integer(R), R >= 0 ->
  check_options(Opts);
check_options([{retry_timeout, T} | Opts]) when is_integer(T), T >= 0 ->
  check_options(Opts);
check_options([{trace, B} | Opts]) when B =:= true; B =:= false ->
  check_options(Opts);
check_options([{transport, T} | Opts]) when T =:= tcp; T =:= tls ->
  check_options(Opts);
check_options([{transport_opts, L} | Opts]) when is_list(L) ->
  check_options(Opts);
check_options([{ws_opts, ProtoOpts} | Opts]) when is_map(ProtoOpts) ->
  case gun_ws:check_options(ProtoOpts) of
    ok ->
      check_options(Opts);
    Error ->
      Error
  end;
check_options([Opt | _]) ->
  {error, {options, Opt}}.

normalize_socket({_Transport, Socket}) -> Socket;
normalize_socket(Socket) -> Socket.

consider_tracing(ServerPid, #{trace := true}) ->
  dbg:start(),
  dbg:tracer(),
  dbg:tpl(gun, [{'_', [], [{return_trace}]}]),
  dbg:tpl(gun_http, [{'_', [], [{return_trace}]}]),
  dbg:tpl(gun_http2, [{'_', [], [{return_trace}]}]),
  dbg:tpl(gun_ws, [{'_', [], [{return_trace}]}]),
  dbg:p(ServerPid, all);
consider_tracing(_, _) ->
  ok.

-spec info(pid()) -> map().
info(ServerPid) ->
  {_, #state{
    socket = Socket,
    proxy_handle = ProxyHandle,
    protocol = Protocol,
    origin_host = OriginHost,
    origin_port = OriginPort,
    intermediaries = Intermediaries
  }} = sys:get_state(ServerPid),
  {ok, {SockIP, SockPort}} = ProxyHandle:sockname(Socket),
  #{
    socket => Socket,
    transport => ProxyHandle:name(),
    protocol => Protocol:name(),
    sock_ip => SockIP,
    sock_port => SockPort,
    origin_host => OriginHost,
    origin_port => OriginPort,
    %% Intermediaries are listed in the order data goes through them.
    intermediaries => lists:reverse(Intermediaries)
  }.

-spec close(pid()) -> ok.
close(ServerPid) ->
  supervisor:terminate_child(gun_sup, ServerPid).

-spec shutdown(pid()) -> ok.
shutdown(ServerPid) ->
  ServerPid ! {shutdown, self()},
  gun_stats:stop_connection(ServerPid),
  ok.

%% Requests.

-spec delete(pid(), iodata()) -> reference().
delete(ServerPid, Path) ->
  request(ServerPid, <<"DELETE">>, Path, []).

-spec delete(pid(), iodata(), headers()) -> reference().
delete(ServerPid, Path, Headers) ->
  request(ServerPid, <<"DELETE">>, Path, Headers).

-spec delete(pid(), iodata(), headers(), req_opts()) -> reference().
delete(ServerPid, Path, Headers, ReqOpts) ->
  request(ServerPid, <<"DELETE">>, Path, Headers, <<>>, ReqOpts).

-spec get(pid(), iodata()) -> reference().
get(ServerPid, Path) ->
  request(ServerPid, <<"GET">>, Path, []).

-spec get(pid(), iodata(), headers()) -> reference().
get(ServerPid, Path, Headers) ->
  request(ServerPid, <<"GET">>, Path, Headers).

-spec get(pid(), iodata(), headers(), req_opts()) -> reference().
get(ServerPid, Path, Headers, ReqOpts) ->
  request(ServerPid, <<"GET">>, Path, Headers, <<>>, ReqOpts).

-spec head(pid(), iodata()) -> reference().
head(ServerPid, Path) ->
  request(ServerPid, <<"HEAD">>, Path, []).

-spec head(pid(), iodata(), headers()) -> reference().
head(ServerPid, Path, Headers) ->
  request(ServerPid, <<"HEAD">>, Path, Headers).

-spec head(pid(), iodata(), headers(), req_opts()) -> reference().
head(ServerPid, Path, Headers, ReqOpts) ->
  request(ServerPid, <<"HEAD">>, Path, Headers, <<>>, ReqOpts).

-spec options(pid(), iodata()) -> reference().
options(ServerPid, Path) ->
  request(ServerPid, <<"OPTIONS">>, Path, []).

-spec options(pid(), iodata(), headers()) -> reference().
options(ServerPid, Path, Headers) ->
  request(ServerPid, <<"OPTIONS">>, Path, Headers).

-spec options(pid(), iodata(), headers(), req_opts()) -> reference().
options(ServerPid, Path, Headers, ReqOpts) ->
  request(ServerPid, <<"OPTIONS">>, Path, Headers, <<>>, ReqOpts).

-spec patch(pid(), iodata(), headers()) -> reference().
patch(ServerPid, Path, Headers) ->
  request(ServerPid, <<"PATCH">>, Path, Headers).

-spec patch(pid(), iodata(), headers(), iodata()) -> reference().
patch(ServerPid, Path, Headers, Body) ->
  request(ServerPid, <<"PATCH">>, Path, Headers, Body).

-spec patch(pid(), iodata(), headers(), iodata(), req_opts()) -> reference().
patch(ServerPid, Path, Headers, Body, ReqOpts) ->
  request(ServerPid, <<"PATCH">>, Path, Headers, Body, ReqOpts).

-spec post(pid(), iodata(), headers()) -> reference().
post(ServerPid, Path, Headers) ->
  request(ServerPid, <<"POST">>, Path, Headers).

-spec post(pid(), iodata(), headers(), iodata()) -> reference().
post(ServerPid, Path, Headers, Body) ->
  request(ServerPid, <<"POST">>, Path, Headers, Body).

-spec post(pid(), iodata(), headers(), iodata(), req_opts()) -> reference().
post(ServerPid, Path, Headers, Body, ReqOpts) ->
  request(ServerPid, <<"POST">>, Path, Headers, Body, ReqOpts).

-spec put(pid(), iodata(), headers()) -> reference().
put(ServerPid, Path, Headers) ->
  request(ServerPid, <<"PUT">>, Path, Headers).

-spec put(pid(), iodata(), headers(), iodata()) -> reference().
put(ServerPid, Path, Headers, Body) ->
  request(ServerPid, <<"PUT">>, Path, Headers, Body).

-spec put(pid(), iodata(), headers(), iodata(), req_opts()) -> reference().
put(ServerPid, Path, Headers, Body, ReqOpts) ->
  request(ServerPid, <<"PUT">>, Path, Headers, Body, ReqOpts).

-spec request(pid(), iodata(), iodata(), headers()) -> reference().
request(ServerPid, Method, Path, Headers) ->
  request(ServerPid, Method, Path, Headers, <<>>, #{}).

-spec request(pid(), iodata(), iodata(), headers(), iodata()) -> reference().
request(ServerPid, Method, Path, Headers, Body) ->
  request(ServerPid, Method, Path, Headers, Body, #{}).

-spec request(pid(), iodata(), iodata(), headers(), iodata(), req_opts()) -> reference().
request(ServerPid, Method, Path, Headers, Body, ReqOpts) ->
  StreamRef = make_ref(),
  ReplyTo = maps:get(reply_to, ReqOpts, self()),
  ServerPid ! {request, ReplyTo, StreamRef, Method, Path, normalize_headers(Headers), Body},
  StreamRef.

%%normalize_headers([]) ->
%%	[];
%%normalize_headers([{Name, Value}|Tail]) when is_binary(Name) ->
%%	[{string:lowercase(Name), Value}|normalize_headers(Tail)];
%%normalize_headers([{Name, Value}|Tail]) when is_list(Name) ->
%%	[{string:lowercase(unicode:characters_to_binary(Name)), Value}|normalize_headers(Tail)];
%%normalize_headers([{Name, Value}|Tail]) when is_atom(Name) ->
%%	[{string:lowercase(atom_to_binary(Name, latin1)), Value}|normalize_headers(Tail)];
%%normalize_headers(Headers) when is_map(Headers) ->
%%	normalize_headers(maps:to_list(Headers)).

normalize_headers(Headers) when is_map(Headers) ->
  maps:to_list(Headers);
normalize_headers(Headers) when is_list(Headers) ->
  Headers.

%% Streaming data.

-spec data(pid(), reference(), fin | nofin, iodata()) -> ok.
data(ServerPid, StreamRef, IsFin, Data) ->
  ServerPid ! {data, self(), StreamRef, IsFin, Data},
  ok.

%% Tunneling.

-spec connect(pid(), connect_destination()) -> reference().
connect(ServerPid, Destination) ->
  connect(ServerPid, Destination, [], #{}).

-spec connect(pid(), connect_destination(), headers()) -> reference().
connect(ServerPid, Destination, Headers) ->
  connect(ServerPid, Destination, Headers, #{}).

-spec connect(pid(), connect_destination(), headers(), req_opts()) -> reference().
connect(ServerPid, Destination, Headers, ReqOpts) ->
  StreamRef = make_ref(),
  ReplyTo = maps:get(reply_to, ReqOpts, self()),
  ServerPid ! {connect, ReplyTo, StreamRef, Destination, Headers},
  StreamRef.

%% Awaiting gun messages.

%% @todo spec await await_body

await(ServerPid, StreamRef) ->
  MRef = monitor(process, ServerPid),
  Res = await(ServerPid, StreamRef, 5000, MRef),
  demonitor(MRef, [flush]),
  Res.

await(ServerPid, StreamRef, MRef) when is_reference(MRef) ->
  await(ServerPid, StreamRef, 5000, MRef);
await(ServerPid, StreamRef, Timeout) ->
  MRef = monitor(process, ServerPid),
  Res = await(ServerPid, StreamRef, Timeout, MRef),
  demonitor(MRef, [flush]),
  Res.

%% @todo Add gun_upgrade and gun_ws?
await(ServerPid, StreamRef, Timeout, MRef) ->
  receive
    {gun_inform, ServerPid, StreamRef, Status, Headers} ->
      {inform, Status, Headers};
    {gun_response, ServerPid, StreamRef, IsFin, Status, Headers} ->
      {response, IsFin, Status, Headers};
    {gun_data, ServerPid, StreamRef, IsFin, Data} ->
      {data, IsFin, Data};
    {gun_trailers, ServerPid, StreamRef, Trailers} ->
      {trailers, Trailers};
    {gun_push, ServerPid, StreamRef, NewStreamRef, Method, URI, Headers} ->
      {push, NewStreamRef, Method, URI, Headers};
    {gun_error, ServerPid, StreamRef, Reason} ->
      {error, Reason};
    {gun_error, ServerPid, Reason} ->
      {error, Reason};
    {'DOWN', MRef, process, ServerPid, Reason} ->
      {error, Reason}
  after Timeout ->
    {error, timeout}
  end.

await_body(ServerPid, StreamRef) ->
  MRef = monitor(process, ServerPid),
  Res = await_body(ServerPid, StreamRef, 5000, MRef, <<>>),
  demonitor(MRef, [flush]),
  Res.

await_body(ServerPid, StreamRef, MRef) when is_reference(MRef) ->
  await_body(ServerPid, StreamRef, 5000, MRef, <<>>);
await_body(ServerPid, StreamRef, Timeout) ->
  MRef = monitor(process, ServerPid),
  Res = await_body(ServerPid, StreamRef, Timeout, MRef, <<>>),
  demonitor(MRef, [flush]),
  Res.

await_body(ServerPid, StreamRef, Timeout, MRef) ->
  await_body(ServerPid, StreamRef, Timeout, MRef, <<>>).

await_body(ServerPid, StreamRef, Timeout, MRef, Acc) ->
  receive
    {gun_data, ServerPid, StreamRef, nofin, Data} ->
      await_body(ServerPid, StreamRef, Timeout, MRef,
        <<Acc/binary, Data/binary>>);
    {gun_data, ServerPid, StreamRef, fin, Data} ->
      {ok, <<Acc/binary, Data/binary>>};
  %% It's OK to return trailers here because the client
  %% specifically requested them.
    {gun_trailers, ServerPid, StreamRef, Trailers} ->
      {ok, Acc, Trailers};
    {gun_error, ServerPid, StreamRef, Reason} ->
      {error, Reason};
    {gun_error, ServerPid, Reason} ->
      {error, Reason};
    {'DOWN', MRef, process, ServerPid, Reason} ->
      {error, Reason}
  after Timeout ->
    {error, timeout}
  end.

-spec await_up(pid()) -> {ok, http | http2} | {error, atom()}.
await_up(ServerPid) ->
  MRef = monitor(process, ServerPid),
  Res = await_up(ServerPid, 5000, MRef),
  demonitor(MRef, [flush]),
  Res.

-spec await_up(pid(), reference() | timeout()) -> {ok, http | http2} | {error, atom()}.
await_up(ServerPid, MRef) when is_reference(MRef) ->
  await_up(ServerPid, 5000, MRef);
await_up(ServerPid, Timeout) ->
  MRef = monitor(process, ServerPid),
  Res = await_up(ServerPid, Timeout, MRef),
  demonitor(MRef, [flush]),
  Res.

-spec await_up(pid(), timeout(), reference()) -> {ok, http | http2} | {error, atom()}.
await_up(ServerPid, Timeout, MRef) ->
  receive
    {gun_up, ServerPid, Protocol} ->
      {ok, Protocol};
    {'DOWN', MRef, process, ServerPid, Reason} ->
      {error, Reason}
  after Timeout ->
    {error, timeout}
  end.

-spec flush(pid() | reference()) -> ok.
flush(ServerPid) when is_pid(ServerPid) ->
  flush_pid(ServerPid);
flush(StreamRef) ->
  flush_ref(StreamRef).

flush_pid(ServerPid) ->
  receive
    {gun_up, ServerPid, _} ->
      flush_pid(ServerPid);
    {gun_down, ServerPid, _, _, _, _} ->
      flush_pid(ServerPid);
    {gun_inform, ServerPid, _, _, _} ->
      flush_pid(ServerPid);
    {gun_response, ServerPid, _, _, _, _} ->
      flush_pid(ServerPid);
    {gun_data, ServerPid, _, _, _} ->
      flush_pid(ServerPid);
    {gun_trailers, ServerPid, _, _} ->
      flush_pid(ServerPid);
    {gun_push, ServerPid, _, _, _, _, _, _} ->
      flush_pid(ServerPid);
    {gun_error, ServerPid, _, _} ->
      flush_pid(ServerPid);
    {gun_error, ServerPid, _} ->
      flush_pid(ServerPid);
    {gun_upgrade, ServerPid, _, _, _} ->
      flush_pid(ServerPid);
    {gun_ws, ServerPid, _, _} ->
      flush_pid(ServerPid);
    {'DOWN', _, process, ServerPid, _} ->
      flush_pid(ServerPid)
  after 0 ->
    ok
  end.

flush_ref(StreamRef) ->
  receive
    {gun_inform, _, StreamRef, _, _} ->
      flush_pid(StreamRef);
    {gun_response, _, StreamRef, _, _, _} ->
      flush_ref(StreamRef);
    {gun_data, _, StreamRef, _, _} ->
      flush_ref(StreamRef);
    {gun_trailers, _, StreamRef, _} ->
      flush_ref(StreamRef);
    {gun_push, _, StreamRef, _, _, _, _, _} ->
      flush_ref(StreamRef);
    {gun_error, _, StreamRef, _} ->
      flush_ref(StreamRef);
    {gun_upgrade, _, StreamRef, _, _} ->
      flush_ref(StreamRef);
    {gun_ws, _, StreamRef, _} ->
      flush_ref(StreamRef)
  after 0 ->
    ok
  end.

%% Cancelling a stream.

-spec cancel(pid(), reference()) -> ok.
cancel(ServerPid, StreamRef) ->
  ServerPid ! {cancel, self(), StreamRef},
  ok.

%% @todo Allow upgrading an HTTP/1.1 connection to HTTP/2.
%% http2_upgrade

%% Websocket.

-spec ws_upgrade(pid(), iodata()) -> reference().
ws_upgrade(ServerPid, Path) ->
  ws_upgrade(ServerPid, Path, []).

-spec ws_upgrade(pid(), iodata(), headers()) -> reference().
ws_upgrade(ServerPid, Path, Headers) ->
  StreamRef = make_ref(),
  ServerPid ! {ws_upgrade, self(), StreamRef, Path, Headers},
  StreamRef.

-spec ws_upgrade(pid(), iodata(), headers(), ws_opts()) -> reference().
ws_upgrade(ServerPid, Path, Headers, Opts) ->
  ok = gun_ws:check_options(Opts),
  StreamRef = make_ref(),
  ServerPid ! {ws_upgrade, self(), StreamRef, Path, Headers, Opts},
  StreamRef.

%% @todo ws_send/2 will need to be deprecated in favor of a variant with StreamRef.
%% But it can be kept for the time being since it can still work for HTTP/1.1.
-spec ws_send(pid(), ws_frame() | [ws_frame()]) -> ok.
ws_send(ServerPid, Frames) ->
  ServerPid ! {ws_send, self(), Frames},
  ok.

%% Internals.

start_link(Owner, Host, Port, Opts) ->
  proc_lib:start_link(?MODULE, proc_lib_hack,
    [self(), Owner, Host, Port, Opts]).

proc_lib_hack(Parent, Owner, Host, Port, Opts) ->
  try
    init(Parent, Owner, Host, Port, Opts)
  catch
    _:normal -> exit(normal);
    _:shutdown -> exit(shutdown);
    _:{shutdown, _} = Reason ->
      exit(Reason);
    _:Reason:StackTrace -> exit({Reason, StackTrace})
  end.

init(Parent, Owner, Host, Port, Opts) ->
  ok = proc_lib:init_ack(Parent, {ok, self()}),
  Retry = maps:get(retry, Opts, 0),
  Transport = case maps:get(transport, Opts, default_transport(Port)) of
                tcp -> gun_tcp;
                tls -> gun_tls
              end,
  % PATCH BEGIN
  {ProxyHandle, ProxyOpt, Host1, Port1} = case maps:get(proxy, Opts, undefined) of
	 	Url when is_binary(Url) orelse is_list(Url) ->
      Url1 = gun_url:parse_url(Url),
      #{host := ProxyHost, port := ProxyPort} = gun_url:normalize(Url1),
      {ProxyUser, ProxyPass} =
        case maps:get(proxy_auth, Opts) of
          {U, P} -> {U, P};
          _ -> {undefined, undefined}
        end,
			Insecure = maps:get(insecure, Opts, true),
      PO = [{connect_host, Host}, {connect_port, Port}, {connect_transport, Transport},
        {connect_user, ProxyUser}, {connect_pass, ProxyPass}, {insecure, Insecure}],
      select_http_proxy(Transport, PO, ProxyHost, ProxyPort);
    {ProxyHost, ProxyPort} ->
      {ProxyUser, ProxyPass} =
        case maps:get(proxy_auth, Opts, nil) of
          {U, P} -> {U, P};
          _ -> {undefined, undefined}
        end,
			Insecure = maps:get(insecure, Opts, true),
      PO = [{connect_host, Host}, {connect_port, Port}, {connect_transport, Transport},
        {connect_user, ProxyUser}, {connect_pass, ProxyPass}, {insecure, Insecure}],
      select_http_proxy(Transport, PO, ProxyHost, ProxyPort);
    {connect, ProxyHost, ProxyPort} ->
      {ProxyUser, ProxyPass} =
        case maps:get(proxy_auth, Opts, nil) of
          {U, P} -> {U, P};
          _ -> {undefined, undefined}
        end,
			Insecure = maps:get(insecure, Opts, true),
      PO = [{connect_host, Host}, {connect_port, Port}, {connect_transport, Transport},
        {connect_user, ProxyUser}, {connect_pass, ProxyPass}, {insecure, Insecure}],
      select_http_proxy(Transport, PO, ProxyHost, ProxyPort);
    {socks5, ProxyHost, ProxyPort} ->
      {ProxyUser, ProxyPass} =
        case maps:get(proxy_auth, Opts, nil) of
          {U, P} -> {U, P};
          _ -> {undefined, undefined}
        end,
			Insecure = maps:get(insecure, Opts, true),
      ProxyResolve = maps:get(socks5_resolve, Opts, undefined),
      PO = [{socks5_host, ProxyHost}, {socks5_port, ProxyPort}, {socks5_user, ProxyUser}, {socks5_pass, ProxyPass},
        {socks5_resolve, ProxyResolve}, {socks5_transport, Transport}, {insecure, Insecure}],
      {gun_socks5_proxy, PO, Host, Port};
	 	_ ->
      {Transport, [], Host, Port}
 	end,
  gun_stats:new_connection(self()),
  gun_stats:update_counter(active_connection, 1),
  gun_stats:update_counter(total_connection, 1),
  % PATCH END
  OwnerRef = monitor(process, Owner),
  transport_connect(#state{parent = Parent, owner = Owner, owner_ref = OwnerRef,
    host = Host1, port = Port1, origin_host = Host, origin_port = Port,
    opts = Opts, transport = Transport, proxy_handle = ProxyHandle, proxy_opt = ProxyOpt}, Retry).

default_transport(443) -> tls;
default_transport(_) -> tcp.


transport_connect(State = #state{host = Host, port = Port, opts = Opts,
  proxy_handle = ProxyHandle, proxy_opt = ProxyOpts, transport = gun_tls}, Retries) ->
  TransportOpts = format_proxy_opts(ProxyHandle, ProxyOpts,
    [binary, {active, false} | ensure_alpn(maps:get(protocols, Opts, [http2, http]), maps:get(transport_opts, Opts, []))]),
  case ProxyHandle:connect(Host, Port, TransportOpts, maps:get(connect_timeout, Opts, 30000)) of
    {ok, SocketT} ->
      Socket = normalize_socket(SocketT),
      {Protocol, ProtoOptsKey} = case ssl:negotiated_protocol(Socket) of
                                   {ok, <<"h2">>} -> {gun_http2, http2_opts};
                                   _ -> {gun_http, http_opts}
                                 end,
      case gun_stats:connection_active(self()) of
        true ->
          up(State, SocketT, Protocol, ProtoOptsKey);
        false ->
          ProxyHandle:close(SocketT),
          exit_or_error(exit, normal)
      end;
    {error, Reason} ->
      case gun_stats:connection_active(self()) of
        true ->
          retry(State#state{last_error = Reason}, Retries);
        false ->
          exit_or_error(exit, normal)
      end
  end;
transport_connect(State = #state{host = Host, port = Port, opts = Opts, proxy_handle = ProxyHandle, proxy_opt = ProxyOpts}, Retries) ->
  TransportOpts = format_proxy_opts(ProxyHandle, ProxyOpts,
    ensure_gun_tcp_opt([binary, {active, false} | maps:get(transport_opts, Opts, [])])),
  case ProxyHandle:connect(Host, Port, TransportOpts, maps:get(connect_timeout, Opts, 30000)) of
    {ok, Socket} ->
      {Protocol, ProtoOptsKey} = case maps:get(protocols, Opts, [http]) of
                                   [http] -> {gun_http, http_opts};
                                   [http2] -> {gun_http2, http2_opts}
                                 end,
      case gun_stats:connection_active(self()) of
        true ->
          up(State, Socket, Protocol, ProtoOptsKey);
        false ->
          ProxyHandle:close(Socket),
          exit_or_error(exit, normal)
      end;
    {error, Reason} ->
      case gun_stats:connection_active(self()) of
        true ->
          retry(State#state{last_error = Reason}, Retries);
        false ->
          exit_or_error(exit, normal)
      end
  end.

ensure_alpn(Protocols0, TransportOpts) ->
  Protocols = [case P of
                 http -> <<"http/1.1">>;
                 http2 -> <<"h2">>
               end || P <- Protocols0],
  [
    {alpn_advertised_protocols, Protocols},
    {client_preferred_next_protocols, {client, Protocols, <<"http/1.1">>}}
    | TransportOpts].

up(State = #state{owner = Owner, opts = Opts, transport = Transport}, SocketT, Protocol, ProtoOptsKey) ->
  ProtoOpts = maps:get(ProtoOptsKey, Opts, #{}),
  Socket = normalize_socket(SocketT),
  ProtoState = Protocol:init(Owner, Socket, Transport, ProtoOpts),
  Owner ! {gun_up, self(), Protocol:name()},
  NewOpts = maps:put(retry, 0, Opts),
  before_loop(State#state{opts = NewOpts, socket = Socket, socket_t = SocketT, protocol = Protocol, protocol_state = ProtoState}).

down(State = #state{owner = Owner, opts = Opts, protocol = Protocol, protocol_state = ProtoState}, Reason) ->
  {KilledStreams, UnprocessedStreams} = Protocol:down(ProtoState),
  send_owner(Owner, {gun_down, self(), Protocol:name(), Reason, KilledStreams, UnprocessedStreams}),
  retry(State#state{socket = undefined, protocol = undefined, protocol_state = undefined,
    last_error = Reason}, maps:get(retry, Opts, 0)).

retry(#state{last_error = Reason}, 0) ->
  exit_or_error(exit, {shutdown, Reason});
retry(State = #state{keepalive_ref = KeepaliveRef}, Retries) when is_reference(KeepaliveRef) ->
  _ = erlang:cancel_timer(KeepaliveRef),
  %% Flush if we have a keepalive message
  receive
    keepalive -> ok
  after 0 ->
    ok
  end,
  retry_loop(State#state{keepalive_ref = undefined}, Retries - 1);
retry(State, Retries) ->
  retry_loop(State, Retries - 1).

retry_loop(State = #state{parent = Parent, opts = Opts}, Retries) ->
  _ = erlang:send_after(maps:get(retry_timeout, Opts, 5000), self(), retry),
  receive
    retry ->
      transport_connect(State, Retries);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [],
        {retry_loop, State, Retries})
  end.

before_loop(State = #state{opts = Opts, protocol = Protocol}) ->
  %% @todo Might not be worth checking every time?
  ProtoOptsKey = case Protocol of
                   gun_http -> http_opts;
                   gun_http2 -> http2_opts
                 end,
  ProtoOpts = maps:get(ProtoOptsKey, Opts, #{}),
  Keepalive = maps:get(keepalive, ProtoOpts, 5000),
  KeepaliveRef = case Keepalive of
                   infinity -> undefined;
                   _ -> erlang:send_after(Keepalive, self(), keepalive)
                 end,
  loop(State#state{keepalive_ref = KeepaliveRef}).

loop(State = #state{parent = Parent, owner = Owner, owner_ref = OwnerRef,
  origin_host = Host, origin_port = Port, opts = Opts, socket = Socket,
  transport = Transport, protocol = Protocol, protocol_state = ProtoState,
  socket_t = SocketT, proxy_handle = ProxyHandle}) ->
  {OK, Closed, Error} = Transport:messages(),
  ProxyHandle:setopts(SocketT, [{active, once}]),
  receive
    %% handle shutdown asap
    {shutdown, Owner} ->
      Protocol:close(ProtoState),
      ProxyHandle:close(SocketT),
      exit_or_error(return, ok);
    %% handle socket data
    {OK, Socket, Data} ->
      case Protocol:handle(Data, ProtoState) of
        Commands when is_list(Commands) ->
          commands(Commands, State);
        Command ->
          commands([Command], State)
      end;
    {Closed, Socket} ->
      Protocol:close(ProtoState),
      ProxyHandle:close(SocketT),
      down(State, closed);
    {Error, Socket, Reason} ->
      Protocol:close(ProtoState),
      ProxyHandle:close(SocketT),
      down(State, {error, Reason});
    {OK, _PreviousSocket, _Data} ->
      loop(State);
    {Closed, _PreviousSocket} ->
      loop(State);
    {Error, _PreviousSocket, _} ->
      loop(State);
    keepalive ->
      ProtoState2 = Protocol:keepalive(ProtoState),
      before_loop(State#state{protocol_state = ProtoState2});
    {request, ReplyTo, StreamRef, Method, Path, Headers, <<>>} ->
      % PATCH BEGIN
      {Path1, Headers1} = format_path_headers(ProxyHandle, Host, Port, Path, Headers, Opts),
      % PATCH END
      ProtoState2 = Protocol:request(ProtoState,
        StreamRef, ReplyTo, Method, Host, Port, Path1, Headers1),
      loop(State#state{protocol_state = ProtoState2});
    {request, ReplyTo, StreamRef, Method, Path, Headers, Body} ->
      % PATCH BEGIN
      {Path1, Headers1} = format_path_headers(ProxyHandle, Host, Port, Path, Headers, Opts),
      % PATCH END
      ProtoState2 = Protocol:request(ProtoState,
        StreamRef, ReplyTo, Method, Host, Port, Path1, Headers1, Body),
      loop(State#state{protocol_state = ProtoState2});
    %% @todo Do we want to reject ReplyTo if it's not the process
    %% who initiated the connection? For both data and cancel.
    {data, ReplyTo, StreamRef, IsFin, Data} ->
      ProtoState2 = Protocol:data(ProtoState,
        StreamRef, ReplyTo, IsFin, Data),
      loop(State#state{protocol_state = ProtoState2});
    {connect, ReplyTo, StreamRef, Destination0, Headers} ->
      %% The protocol option has been deprecated in favor of the protocols option.
      %% Nobody probably ended up using it, but let's not break the interface.
      Destination1 = case Destination0 of
                       #{protocols := _} ->
                         Destination0;
                       #{protocol := DestProto} ->
                         Destination0#{protocols => [DestProto]};
                       _ ->
                         Destination0
                     end,
      Destination = case Destination1 of
                      #{transport := tls} ->
                        Destination1#{tls_opts => ensure_alpn(
                          maps:get(protocols, Destination1, [http]),
                          maps:get(tls_opts, Destination1, []))};
                      _ ->
                        Destination1
                    end,
      ProtoState2 = Protocol:connect(ProtoState, StreamRef, ReplyTo, Destination, Headers),
      loop(State#state{protocol_state = ProtoState2});
    {cancel, ReplyTo, StreamRef} ->
      ProtoState2 = Protocol:cancel(ProtoState, StreamRef, ReplyTo),
      loop(State#state{protocol_state = ProtoState2});
    %% @todo Maybe make an interface in the protocol module instead of checking on protocol name.
    %% An interface would also make sure that HTTP/1.0 can't upgrade.
    {ws_upgrade, Owner, StreamRef, Path, Headers} when Protocol =:= gun_http ->
      WsOpts = maps:get(ws_opts, Opts, #{}),
      ProtoState2 = Protocol:ws_upgrade(ProtoState, StreamRef, Host, Port, Path, Headers, WsOpts),
      loop(State#state{protocol_state = ProtoState2});
    {ws_upgrade, Owner, StreamRef, Path, Headers, WsOpts} when Protocol =:= gun_http ->
      ProtoState2 = Protocol:ws_upgrade(ProtoState, StreamRef, Host, Port, Path, Headers, WsOpts),
      loop(State#state{protocol_state = ProtoState2});
    {'DOWN', OwnerRef, process, Owner, Reason} ->
      Protocol:close(ProtoState),
      ProxyHandle:close(SocketT),
      owner_gone(Reason);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {loop, State});
    {ws_upgrade, _, StreamRef, _, _} ->
      Owner ! {gun_error, self(), StreamRef, {badstate, "Websocket is only supported over HTTP/1.1."}},
      loop(State);
    {ws_upgrade, _, StreamRef, _, _, _} ->
      Owner ! {gun_error, self(), StreamRef, {badstate, "Websocket is only supported over HTTP/1.1."}},
      loop(State);
    {ws_send, _, _} ->
      Owner ! {gun_error, self(), {badstate, "Connection needs to be upgraded to Websocket before the gun:ws_send/1 function can be used."}},
      loop(State);
    %% @todo The ReplyTo patch disabled the notowner behavior.
    %% We need to add an option to enforce this behavior if needed.
    Any when is_tuple(Any), is_pid(element(2, Any)) ->
      element(2, Any) ! {gun_error, self(), {notowner, "Operations are restricted to the owner of the connection."}},
      loop(State);
    Any ->
      error_logger:error_msg("Unexpected message: ~w~n", [Any]),
      loop(State)
  end.

commands([], State) ->
  loop(State);
commands([close | _], State = #state{socket_t = SocketT, proxy_handle = ProxyHandle}) ->
  ProxyHandle:close(SocketT),
  down(State, normal);
commands([Error = {error, _} | _], State = #state{socket_t = SocketT, proxy_handle = ProxyHandle}) ->
  ProxyHandle:close(SocketT),
  down(State, Error);
commands([{state, ProtoState} | Tail], State) ->
  commands(Tail, State#state{protocol_state = ProtoState});
%% @todo The scheme should probably not be ignored.
%%
%% Order is important: the origin must be changed before
%% the transport and/or protocol in order to keep track
%% of the intermediaries properly.
commands([{origin, _Scheme, Host, Port, Type} | Tail],
    State = #state{transport = Transport, protocol = Protocol,
      origin_host = IntermediateHost, origin_port = IntermediatePort,
      intermediaries = Intermediaries}) ->
  Info = #{
    type => Type,
    host => IntermediateHost,
    port => IntermediatePort,
    transport => Transport:name(),
    protocol => Protocol:name()
  },
  commands(Tail, State#state{origin_host = Host, origin_port = Port,
    intermediaries = [Info | Intermediaries]});
commands([{switch_transport, Transport, Socket} | Tail], State) ->
  commands(Tail, State#state{socket = Socket, transport = Transport});
%% @todo The two loops should be reunified and this clause generalized.
commands([{switch_protocol, Protocol = gun_ws, ProtoState}], State) ->
  ws_loop(State#state{protocol = Protocol, protocol_state = ProtoState});
%% @todo And this state should probably not be ignored.
commands([{switch_protocol, Protocol, _ProtoState0} | Tail],
    State = #state{owner = Owner, opts = Opts, socket = Socket, transport = Transport}) ->
  ProtoOpts = maps:get(http2_opts, Opts, #{}),
  ProtoState = Protocol:init(Owner, Socket, Transport, ProtoOpts),
  commands(Tail, State#state{protocol = Protocol, protocol_state = ProtoState}).

ws_loop(State = #state{parent = Parent, owner = Owner, owner_ref = OwnerRef, socket = Socket,
  transport = Transport, protocol = Protocol, protocol_state = ProtoState,
  socket_t = SocketT, proxy_handle = ProxyHandle}) ->
  {OK, Closed, Error} = Transport:messages(),
  Transport:setopts(Socket, [{active, once}]),
  receive
    % handle shutdown
    {shutdown, Owner} ->
      Protocol:close(ProtoState),
      ProxyHandle:close(SocketT),
      exit_or_error(return, ok);
    % handle socket data
    {OK, Socket, Data} ->
      case Protocol:handle(Data, ProtoState) of
        close ->
          ProxyHandle:close(SocketT),
          down(State, normal);
        ProtoState2 ->
          ws_loop(State#state{protocol_state = ProtoState2})
      end;
    {Closed, Socket} ->
      ProxyHandle:close(SocketT),
      down(State, closed);
    {Error, Socket, Reason} ->
      ProxyHandle:close(SocketT),
      down(State, {error, Reason});
  %% Ignore any previous HTTP keep-alive.
    keepalive ->
      ws_loop(State);
%		{ws_send, Owner, Frames} when is_list(Frames) ->
%			todo; %% @todo
    {ws_send, Owner, Frame} ->
      case Protocol:send(Frame, ProtoState) of
        close ->
          ProxyHandle:close(SocketT),
          down(State, normal);
        ProtoState2 ->
          ws_loop(State#state{protocol_state = ProtoState2})
      end;
    {'DOWN', OwnerRef, process, Owner, Reason} ->
      Protocol:close(owner_gone, ProtoState),
      ProxyHandle:close(SocketT),
      owner_gone(Reason);
    {system, From, Request} ->
      sys:handle_system_msg(Request, From, Parent, ?MODULE, [], {ws_loop, State});
    Any when is_tuple(Any), is_pid(element(2, Any)) ->
      element(2, Any) ! {gun_error, self(), {notowner, "Operations are restricted to the owner of the connection."}},
      ws_loop(State);
    Any ->
      error_logger:error_msg("Unexpected message: ~w~n", [Any]),
      exit_or_error(exit, badarg)
  end.

-spec owner_gone(_) -> no_return().
owner_gone(normal) ->
  exit_or_error(exit, normal);
owner_gone(shutdown) ->
  exit_or_error(exit, shutdown);
owner_gone(Shutdown = {shutdown, _}) ->
  exit_or_error(exit, Shutdown);
owner_gone(Reason) ->
  exit_or_error(error, {owner_gone, Reason}).

system_continue(_, _, {retry_loop, State, Retry}) ->
  retry_loop(State, Retry);
system_continue(_, _, {loop, State}) ->
  loop(State);
system_continue(_, _, {ws_loop, State}) ->
  ws_loop(State).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, _) ->
  exit_or_error(exit, Reason).

system_code_change(Misc, _, _, _) ->
  {ok, Misc}.


%% PATCH BEGIN

send_owner(Owner, Msg) ->
  case gun_stats:connection_active(self()) of
    true ->
      Owner ! Msg,
      ok;
    false ->
      ok
  end.

exit_or_error(exit, Reason) ->
  gun_stats:update_counter(active_connection, -1),
  gun_stats:del_connection(self()),
  exit(Reason);
exit_or_error(error, Reason) ->
  gun_stats:update_counter(active_connection, -1),
  gun_stats:del_connection(self()),
  error(Reason);
exit_or_error(return, Result) ->
  gun_stats:update_counter(active_connection, -1),
  gun_stats:del_connection(self()),
  Result.

select_http_proxy(gun_tcp, _PO, ProxyHost, ProxyPort) -> {gun_tcp, [binary, {active, false}], ProxyHost, ProxyPort};
select_http_proxy(_, PO, ProxyHost, ProxyPort) -> {gun_http_proxy, PO, ProxyHost, ProxyPort}.

format_path_headers(gun_tcp, OriginHost, OriginPort, Path, Headers, Opts) ->
	IsProxy = is_http_proxy(Opts),
	case maps:get(proxy_auth, Opts, undefined) of
		{U, P} when IsProxy == true ->
			{add_host_to_path(OriginHost, OriginPort, Path), add_proxy_authorization(U, P, Headers)};
		_ ->
			{Path, Headers}
	end;

format_path_headers(_, _OriginHost, _OriginPort, Path, Headers, _Opts) ->
	{Path, Headers}.

add_host_to_path(OriginHost, OriginPort, Path) ->
	case OriginPort of
		80 ->
			iolist_to_binary([<<"http://">>, OriginHost, Path]);
		_ ->
			iolist_to_binary([<<"http://">>, OriginHost, <<":">>, integer_to_binary(OriginPort), Path])
	end.

add_proxy_authorization(ProxyUser, ProxyPass, Headers) ->
	HasProxyAuthorization = lists:keymember(<<"proxy-authorization">>, 1, Headers),
	case HasProxyAuthorization of
		false ->
			Credentials = base64:encode(<<ProxyUser/binary, ":", ProxyPass/binary>>),
			[{<<"proxy-authorization">>, [<<"Basic ">>, Credentials]} | Headers];
		true ->
			Headers
	end.

is_http_proxy(Opts) ->
	case maps:get(proxy, Opts, undefined) of
		Url when is_binary(Url) orelse is_list(Url) ->
			true;
		{_ProxyHost, _ProxyPort} ->
			true;
		{connect, _ProxyHost, _ProxyPort} ->
			true;
		_ ->
			false
	end.

format_proxy_opts(ProxyHandle, ProxyOpts, TransOpts) ->
  case ProxyHandle of
    gun_http_proxy ->
      [{tcp_opt, TransOpts}| ProxyOpts];
    gun_socks5_proxy ->
      [{tcp_opt, TransOpts}| ProxyOpts];
    gun_tcp ->
      TransOpts;
    gun_tls ->
      TransOpts
  end.

ensure_gun_tcp_opt(TransOpts0) ->
	SslOpts = [verify, verify_fun, fail_if_no_peer_cert, depth, cert, certfile, key, keyfile, password, cacerts,
    cacertfile, dh, dhfile, ciphers, user_lookup_fun, reuse_sessions, reuse_session, next_protocols_advertised,
		client_preferred_next_protocols, alpn_advertised_protocols, log_alert, server_name_indication, customize_hostname_check,
		sni_hosts, sni_fun, protocol, handshake, secure_renegotiate, crl_check, crl_cache, partial_chain, versions],
	lists:filter(fun(X) ->
			case X of
				{K, _} ->
					lists:member(K, SslOpts) == false;
				K ->
					lists:member(K, SslOpts) == false
			end
		end, TransOpts0).
%% PATCH END
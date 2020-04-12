%% Copyright (c) 2016-2019, Loïc Hoguin <essen@ninenines.eu>
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

-module(gun_http2).

-export([check_options/1]).
-export([name/0]).
-export([opts_name/0]).
-export([has_keepalive/0]).
-export([default_keepalive/0]).
-export([init/4]).
-export([switch_transport/3]).
-export([handle/2]).
-export([update_flow/4]).
-export([closing/2]).
-export([close/2]).
-export([keepalive/1]).
-export([headers/9]).
-export([request/10]).
-export([data/5]).
-export([cancel/3]).
-export([timeout/3]).
-export([stream_info/2]).
-export([down/1]).

-record(stream, {
	id = undefined :: cow_http2:streamid(),

	%% Reference used by the user of Gun to refer to this stream.
	ref :: reference(),

	%% Process to send messages to.
	reply_to :: pid(),

	%% Flow control.
	flow :: integer() | infinity,

	%% Request target URI.
	authority :: iodata(),
	path :: iodata(),

	%% Content handlers state.
	handler_state :: undefined | gun_content_handler:state()
}).

-record(http2_state, {
	socket :: inet:socket() | ssl:sslsocket(),
	transport :: module(),
	opts = #{} :: gun:http2_opts(),
	content_handlers :: gun_content_handler:opt(),
	buffer = <<>> :: binary(),

	%% Current status of the connection. We use this to ensure we are
	%% not sending the GOAWAY frame more than once, and to validate
	%% the server connection preface.
	status = preface :: preface | connected | goaway | closing,

	%% HTTP/2 state machine.
	http2_machine :: cow_http2_machine:http2_machine(),

	%% Currently active HTTP/2 streams. Streams may be initiated either
	%% by the client or by the server through PUSH_PROMISE frames.
	%%
	%% Streams can be found by ID or by Ref. The most common should be
	%% the idea, that's why the main map has the ID as key. Then we also
	%% have a Ref->ID index for faster lookup when we only have the Ref.
	streams = #{} :: #{cow_http2:streamid() => #stream{}},
	stream_refs = #{} :: #{reference() => cow_http2:streamid()},

	%% We must queue commands when parsing the incoming data.
	commands_queue = [] :: [{set_cookie, iodata(), iodata(), cow_http:status(), cow_http:headers()}]
}).

check_options(Opts) ->
	do_check_options(maps:to_list(Opts)).

do_check_options([]) ->
	ok;
do_check_options([{closing_timeout, infinity}|Opts]) ->
	do_check_options(Opts);
do_check_options([{closing_timeout, T}|Opts]) when is_integer(T), T > 0 ->
	do_check_options(Opts);
do_check_options([Opt={content_handlers, Handlers}|Opts]) ->
	case gun_content_handler:check_option(Handlers) of
		ok -> do_check_options(Opts);
		error -> {error, {options, {http2, Opt}}}
	end;
do_check_options([{flow, InitialFlow}|Opts]) when is_integer(InitialFlow), InitialFlow > 0 ->
	do_check_options(Opts);
do_check_options([{keepalive, infinity}|Opts]) ->
	do_check_options(Opts);
do_check_options([{keepalive, K}|Opts]) when is_integer(K), K > 0 ->
	do_check_options(Opts);
do_check_options([Opt={Name, _}|Opts]) ->
	%% We blindly accept all cow_http2_machine options.
	HTTP2MachineOpts = [
		connection_window_margin_size,
		connection_window_update_threshold,
		enable_connect_protocol,
		initial_connection_window_size,
		initial_stream_window_size,
		max_connection_window_size,
		max_concurrent_streams,
		max_decode_table_size,
		max_encode_table_size,
		max_frame_size_received,
		max_frame_size_sent,
		max_stream_window_size,
		preface_timeout,
		settings_timeout,
		stream_window_margin_size,
		stream_window_update_threshold
	],
	case lists:member(Name, HTTP2MachineOpts) of
		true -> do_check_options(Opts);
		false -> {error, {options, {http2, Opt}}}
	end.

name() -> http2.
opts_name() -> http2_opts.
has_keepalive() -> true.
default_keepalive() -> 5000.

init(_ReplyTo, Socket, Transport, Opts0) ->
	%% We have different defaults than the protocol in order
	%% to optimize for performance when receiving responses.
	Opts = Opts0#{
		initial_connection_window_size => maps:get(initial_connection_window_size, Opts0, 8000000),
		initial_stream_window_size => maps:get(initial_stream_window_size, Opts0, 8000000)
	},
	{ok, Preface, HTTP2Machine} = cow_http2_machine:init(client, Opts),
	Handlers = maps:get(content_handlers, Opts, [gun_data_h]),
	%% @todo Better validate the preface being received.
	State = #http2_state{socket=Socket,
		transport=Transport, opts=Opts, content_handlers=Handlers,
		http2_machine=HTTP2Machine},
	Transport:send(Socket, Preface),
	{connected, State}.

switch_transport(Transport, Socket, State) ->
	State#http2_state{socket=Socket, transport=Transport}.

%% This function is called before returning from handle/4.
handle_ret(CommandOrCommands, #http2_state{commands_queue=[]}) ->
	CommandOrCommands;
handle_ret(Commands, #http2_state{commands_queue=Queue}) when is_list(Commands) ->
	lists:reverse(Queue, Commands);
handle_ret(Command, #http2_state{commands_queue=Queue}) ->
	lists:reverse([Command|Queue]).

handle(Data, State=#http2_state{buffer=Buffer}) ->
	parse(<< Buffer/binary, Data/binary >>, State#http2_state{buffer= <<>>}).

parse(Data, State0=#http2_state{status=preface, http2_machine=HTTP2Machine}) ->
	MaxFrameSize = cow_http2_machine:get_local_setting(max_frame_size, HTTP2Machine),
	case cow_http2:parse(Data, MaxFrameSize) of
		{ok, Frame, Rest} when element(1, Frame) =:= settings ->
			case frame(State0#http2_state{status=connected}, Frame) of
				Error={error, _} -> handle_ret(Error, State0);
				State -> parse(Rest, State)
			end;
		more ->
			handle_ret({state, State0#http2_state{buffer=Data}}, State0);
		%% Any error in the preface is converted to this specific error
		%% to make debugging the problem easier (it's the server's fault).
		_ ->
			Reason = case Data of
				<<"HTTP/1",_/bits>> ->
					'Invalid connection preface received. Appears to be an HTTP/1 response? (RFC7540 3.5)';
				_ ->
					'Invalid connection preface received. (RFC7540 3.5)'
			end,
			handle_ret(connection_error(State0, {connection_error, protocol_error, Reason}), State0)
	end;
parse(Data, State0=#http2_state{status=Status, http2_machine=HTTP2Machine, streams=Streams}) ->
	MaxFrameSize = cow_http2_machine:get_local_setting(max_frame_size, HTTP2Machine),
	case cow_http2:parse(Data, MaxFrameSize) of
		{ok, Frame, Rest} ->
			case frame(State0, Frame) of
				Error={error, _} -> handle_ret(Error, State0);
				State -> parse(Rest, State)
			end;
		{ignore, Rest} ->
			case ignored_frame(State0) of
				Error = {error, _} -> handle_ret(Error, State0);
				State -> parse(Rest, State)
			end;
		{stream_error, StreamID, Reason, Human, Rest} ->
			parse(Rest, reset_stream(State0, StreamID, {stream_error, Reason, Human}));
		Error = {connection_error, _, _} ->
			handle_ret(connection_error(State0, Error), State0);
		%% If we both received and sent a GOAWAY frame and there are no streams
		%% currently running, we can close the connection immediately.
		more when Status =/= connected, Streams =:= #{} ->
			handle_ret([{state, State0#http2_state{buffer=Data, status=closing}}, close], State0);
		%% Otherwise we enter the closing state.
		more when Status =:= goaway ->
			handle_ret([{state, State0#http2_state{buffer=Data, status=closing}}, closing(State0)], State0);
		more ->
			handle_ret({state, State0#http2_state{buffer=Data}}, State0)
	end.

%% Frames received.

frame(State=#http2_state{http2_machine=HTTP2Machine0}, Frame) ->
	case cow_http2_machine:frame(Frame, HTTP2Machine0) of
		%% We only update the connection's window when receiving a lingering data frame.
		{ok, HTTP2Machine} when element(1, Frame) =:= data ->
			update_window(State#http2_state{http2_machine=HTTP2Machine});
		{ok, HTTP2Machine} ->
			maybe_ack(State#http2_state{http2_machine=HTTP2Machine}, Frame);
		{ok, {data, StreamID, IsFin, Data}, HTTP2Machine} ->
			data_frame(State#http2_state{http2_machine=HTTP2Machine}, StreamID, IsFin, Data);
		{ok, {headers, StreamID, IsFin, Headers, PseudoHeaders, BodyLen}, HTTP2Machine} ->
			headers_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, IsFin, Headers, PseudoHeaders, BodyLen);
		{ok, {trailers, StreamID, Trailers}, HTTP2Machine} ->
			trailers_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, Trailers);
		{ok, {rst_stream, StreamID, Reason}, HTTP2Machine} ->
			rst_stream_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, Reason);
		{ok, {push_promise, StreamID, PromisedStreamID, Headers, PseudoHeaders}, HTTP2Machine} ->
			push_promise_frame(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, PromisedStreamID, Headers, PseudoHeaders);
		{ok, GoAway={goaway, _, _, _}, HTTP2Machine} ->
			goaway(State#http2_state{http2_machine=HTTP2Machine}, GoAway);
		{send, SendData, HTTP2Machine} ->
			send_data(maybe_ack(State#http2_state{http2_machine=HTTP2Machine}, Frame), SendData);
		{error, {stream_error, StreamID, Reason, Human}, HTTP2Machine} ->
			reset_stream(State#http2_state{http2_machine=HTTP2Machine},
				StreamID, {stream_error, Reason, Human});
		{error, Error={connection_error, _, _}, HTTP2Machine} ->
			connection_error(State#http2_state{http2_machine=HTTP2Machine}, Error)
	end.

maybe_ack(State=#http2_state{socket=Socket, transport=Transport}, Frame) ->
	case Frame of
		{settings, _} -> Transport:send(Socket, cow_http2:settings_ack());
		{ping, Opaque} -> Transport:send(Socket, cow_http2:ping_ack(Opaque));
		_ -> ok
	end,
	State.

data_frame(State0, StreamID, IsFin, Data) ->
	Stream = #stream{flow=Flow0,
		handler_state=Handlers0} = get_stream_by_id(State0, StreamID),
	{ok, Dec, Handlers} = gun_content_handler:handle(IsFin, Data, Handlers0),
	Flow = case Flow0 of
		infinity -> infinity;
		_ -> Flow0 - Dec
	end,
	State1 = store_stream(State0, Stream#stream{flow=Flow, handler_state=Handlers}),
	State = case byte_size(Data) of
		%% We do not send a WINDOW_UPDATE if the DATA frame was of size 0.
		0 when IsFin =:= fin ->
			State1;
		0 ->
			State1;
		_ ->
			%% We do not send a stream WINDOW_UPDATE when the flow control kicks in
			%% (it'll be sent when the flow recovers) or for the last DATA frame.
			case IsFin of
				nofin when Flow =< 0 ->
					update_window(State1);
				nofin ->
					update_window(State1, StreamID);
				fin ->
					update_window(State1)
			end
	end,
	maybe_delete_stream(State, StreamID, remote, IsFin).

headers_frame(State0=#http2_state{content_handlers=Handlers0, commands_queue=Commands},
		StreamID, IsFin, Headers, #{status := Status}, _BodyLen) ->
	Stream = get_stream_by_id(State0, StreamID),
	#stream{
		ref=StreamRef,
		reply_to=ReplyTo,
		authority=Authority,
		path=Path
	} = Stream,
	State = State0#http2_state{commands_queue=[{set_cookie, Authority, Path, Status, Headers}|Commands]},
	if
		Status >= 100, Status =< 199 ->
			ReplyTo ! {gun_inform, self(), StreamRef, Status, Headers},
			State;
		true ->
			ReplyTo ! {gun_response, self(), StreamRef, IsFin, Status, Headers},
			Handlers = case IsFin of
				fin ->
					undefined;
				nofin ->
					gun_content_handler:init(ReplyTo, StreamRef,
						Status, Headers, Handlers0)
			end,
			maybe_delete_stream(store_stream(State, Stream#stream{handler_state=Handlers}),
				StreamID, remote, IsFin)
	end.

trailers_frame(State, StreamID, Trailers) ->
	#stream{ref=StreamRef, reply_to=ReplyTo} = get_stream_by_id(State, StreamID),
	%% @todo We probably want to pass this to gun_content_handler?
	ReplyTo ! {gun_trailers, self(), StreamRef, Trailers},
	maybe_delete_stream(State, StreamID, remote, fin).

rst_stream_frame(State0, StreamID, Reason) ->
	case take_stream(State0, StreamID) of
		{#stream{ref=StreamRef, reply_to=ReplyTo}, State} ->
			ReplyTo ! {gun_error, self(), StreamRef,
				{stream_error, Reason, 'Stream reset by server.'}},
			State;
		error ->
			State0
	end.

%% Pushed streams receive the same initial flow value as the parent stream.
push_promise_frame(State=#http2_state{socket=Socket, transport=Transport,
		status=Status, http2_machine=HTTP2Machine0},
		StreamID, PromisedStreamID, Headers,
		#{method := Method, scheme := Scheme, authority := Authority, path := Path}) ->
	#stream{ref=StreamRef, reply_to=ReplyTo, flow=InitialFlow} = get_stream_by_id(State, StreamID),
	PromisedStreamRef = make_ref(),
	URI = iolist_to_binary([Scheme, <<"://">>, Authority, Path]),
	case Status of
		connected ->
			ReplyTo ! {gun_push, self(), StreamRef, PromisedStreamRef, Method, URI, Headers};
		_ ->
			ok
	end,
	case Status of
		connected ->
			NewStream = #stream{id=PromisedStreamID, ref=PromisedStreamRef,
				reply_to=ReplyTo, flow=InitialFlow, authority=Authority, path=Path},
			create_stream(State, NewStream);
		%% We cancel the push_promise immediately when we are shutting down.
		_ ->
			{ok, HTTP2Machine} = cow_http2_machine:reset_stream(PromisedStreamID, HTTP2Machine0),
			Transport:send(Socket, cow_http2:rst_stream(PromisedStreamID, cancel)),
			State#http2_state{http2_machine=HTTP2Machine}
	end.

ignored_frame(State=#http2_state{http2_machine=HTTP2Machine0}) ->
	case cow_http2_machine:ignored_frame(HTTP2Machine0) of
		{ok, HTTP2Machine} ->
			State#http2_state{http2_machine=HTTP2Machine};
		{error, Error={connection_error, _, _}, HTTP2Machine} ->
			connection_error(State#http2_state{http2_machine=HTTP2Machine}, Error)
	end.

update_flow(State, _ReplyTo, StreamRef, Inc) ->
	case get_stream_by_ref(State, StreamRef) of
		Stream=#stream{id=StreamID, flow=Flow0} ->
			Flow = case Flow0 of
				infinity -> infinity;
				_ -> Flow0 + Inc
			end,
			if
				%% Flow is active again, update the stream's window.
				Flow0 =< 0, Flow > 0 ->
					{state, update_window(store_stream(State,
						Stream#stream{flow=Flow}), StreamID)};
				true ->
					{state, store_stream(State, Stream#stream{flow=Flow})}
			end;
		error ->
			[]
	end.

%% Only update the connection's window.
update_window(State=#http2_state{socket=Socket, transport=Transport,
		opts=#{initial_connection_window_size := ConnWindow}, http2_machine=HTTP2Machine0}) ->
	case cow_http2_machine:ensure_window(ConnWindow, HTTP2Machine0) of
		ok ->
			State;
		{ok, Increment, HTTP2Machine} ->
			Transport:send(Socket, cow_http2:window_update(Increment)),
			State#http2_state{http2_machine=HTTP2Machine}
	end.

%% Update both the connection and the stream's window.
update_window(State=#http2_state{socket=Socket, transport=Transport,
		opts=#{initial_connection_window_size := ConnWindow, initial_stream_window_size := StreamWindow},
		http2_machine=HTTP2Machine0}, StreamID) ->
	{Data1, HTTP2Machine2} = case cow_http2_machine:ensure_window(ConnWindow, HTTP2Machine0) of
		ok -> {<<>>, HTTP2Machine0};
		{ok, Increment1, HTTP2Machine1} -> {cow_http2:window_update(Increment1), HTTP2Machine1}
	end,
	{Data2, HTTP2Machine} = case cow_http2_machine:ensure_window(StreamID, StreamWindow, HTTP2Machine2) of
		ok -> {<<>>, HTTP2Machine2};
		{ok, Increment2, HTTP2Machine3} -> {cow_http2:window_update(StreamID, Increment2), HTTP2Machine3}
	end,
	case {Data1, Data2} of
		{<<>>, <<>>} -> ok;
		_ -> Transport:send(Socket, [Data1, Data2])
	end,
	State#http2_state{http2_machine=HTTP2Machine}.

%% We may have to cancel streams even if we receive multiple
%% GOAWAY frames as the LastStreamID value may be lower than
%% the one previously received.
goaway(State0=#http2_state{socket=Socket, transport=Transport, http2_machine=HTTP2Machine,
		status=Status, streams=Streams0, stream_refs=Refs}, {goaway, LastStreamID, Reason, _}) ->
	{Streams, RemovedRefs} = goaway_streams(maps:to_list(Streams0), LastStreamID,
		{goaway, Reason, 'The connection is going away.'}, [], []),
	State = State0#http2_state{
		streams=maps:from_list(Streams),
		stream_refs=maps:without(RemovedRefs, Refs)
	},
	case Status of
		connected ->
			Transport:send(Socket, cow_http2:goaway(
				cow_http2_machine:get_last_streamid(HTTP2Machine),
				no_error, <<>>)),
			State#http2_state{status=goaway};
		_ ->
			State
	end.

%% Cancel server-initiated streams that are above LastStreamID.
goaway_streams([], _, _, Acc, RefsAcc) ->
	{Acc, RefsAcc};
goaway_streams([{StreamID, Stream=#stream{ref=StreamRef}}|Tail], LastStreamID, Reason, Acc, RefsAcc)
		when StreamID > LastStreamID, (StreamID rem 2) =:= 1 ->
	close_stream(Stream, Reason),
	goaway_streams(Tail, LastStreamID, Reason, Acc, [StreamRef|RefsAcc]);
goaway_streams([StreamWithID|Tail], LastStreamID, Reason, Acc, RefsAcc) ->
	goaway_streams(Tail, LastStreamID, Reason, [StreamWithID|Acc], RefsAcc).

%% We are already closing, do nothing.
closing(_, #http2_state{status=closing}) ->
	[];
closing(Reason0, State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine}) ->
	Reason = case Reason0 of
		normal -> no_error;
		owner_down -> no_error;
		_ -> internal_error
	end,
	Transport:send(Socket, cow_http2:goaway(
		cow_http2_machine:get_last_streamid(HTTP2Machine),
		Reason, <<>>)),
	[
		{state, State#http2_state{status=closing}},
		closing(State)
	].

closing(#http2_state{opts=Opts}) ->
	Timeout = maps:get(closing_timeout, Opts, 15000),
	{closing, Timeout}.

close(Reason0, #http2_state{streams=Streams}) ->
	Reason = close_reason(Reason0),
	maps:fold(fun(_, Stream, _) ->
		close_stream(Stream, Reason)
	end, [], Streams),
	ok.

close_reason(closed) -> closed;
close_reason(Reason) -> {closed, Reason}.

%% @todo Do we want an event for this?
close_stream(#stream{ref=StreamRef, reply_to=ReplyTo}, Reason) ->
	ReplyTo ! {gun_error, self(), StreamRef, Reason},
	ok.

keepalive(State=#http2_state{socket=Socket, transport=Transport}) ->
	Transport:send(Socket, cow_http2:ping(0)),
	State.

headers(State=#http2_state{socket=Socket, transport=Transport, opts=Opts,
		http2_machine=HTTP2Machine0}, StreamRef, ReplyTo, Method, Host, Port,
		Path, Headers0, InitialFlow0) ->
	{ok, StreamID, HTTP2Machine1} = cow_http2_machine:init_stream(
		iolist_to_binary(Method), HTTP2Machine0),
	{ok, PseudoHeaders, Headers} = prepare_headers(State, Method, Host, Port, Path, Headers0),
	Authority = maps:get(authority, PseudoHeaders),
	{ok, IsFin, HeaderBlock, HTTP2Machine} = cow_http2_machine:prepare_headers(
		StreamID, HTTP2Machine1, nofin, PseudoHeaders, Headers),
	Transport:send(Socket, cow_http2:headers(StreamID, IsFin, HeaderBlock)),
	InitialFlow = initial_flow(InitialFlow0, Opts),
	Stream = #stream{id=StreamID, ref=StreamRef, reply_to=ReplyTo, flow=InitialFlow,
		authority=Authority, path=Path},
	create_stream(State#http2_state{http2_machine=HTTP2Machine}, Stream).

request(State0=#http2_state{socket=Socket, transport=Transport, opts=Opts,
		http2_machine=HTTP2Machine0}, StreamRef, ReplyTo, Method, Host, Port,
		Path, Headers0, Body, InitialFlow0) ->
	Headers1 = lists:keystore(<<"content-length">>, 1, Headers0,
		{<<"content-length">>, integer_to_binary(iolist_size(Body))}),
	{ok, StreamID, HTTP2Machine1} = cow_http2_machine:init_stream(
		iolist_to_binary(Method), HTTP2Machine0),
	{ok, PseudoHeaders, Headers} = prepare_headers(State0, Method, Host, Port, Path, Headers1),
	Authority = maps:get(authority, PseudoHeaders),
	IsFin0 = case iolist_size(Body) of
		0 -> fin;
		_ -> nofin
	end,
	{ok, IsFin, HeaderBlock, HTTP2Machine} = cow_http2_machine:prepare_headers(
		StreamID, HTTP2Machine1, IsFin0, PseudoHeaders, Headers),
	Transport:send(Socket, cow_http2:headers(StreamID, IsFin, HeaderBlock)),
	InitialFlow = initial_flow(InitialFlow0, Opts),
	Stream = #stream{id=StreamID, ref=StreamRef, reply_to=ReplyTo, flow=InitialFlow,
		authority=Authority, path=Path},
	State = create_stream(State0#http2_state{http2_machine=HTTP2Machine}, Stream),
	case IsFin of
		fin ->
			State;
		nofin ->
			maybe_send_data(State, StreamID, fin, Body)
	end.

initial_flow(infinity, #{flow := InitialFlow}) -> InitialFlow;
initial_flow(InitialFlow, _) -> InitialFlow.

prepare_headers(#http2_state{transport=Transport}, Method, Host0, Port, Path, Headers0) ->
	Authority = case lists:keyfind(<<"host">>, 1, Headers0) of
		{_, Host} -> Host;
		_ -> gun_http:host_header(Transport, Host0, Port)
	end,
	%% @todo We also must remove any header found in the connection header.
	Headers =
		lists:keydelete(<<"host">>, 1,
		lists:keydelete(<<"connection">>, 1,
		lists:keydelete(<<"keep-alive">>, 1,
		lists:keydelete(<<"proxy-connection">>, 1,
		lists:keydelete(<<"transfer-encoding">>, 1,
		lists:keydelete(<<"upgrade">>, 1, Headers0)))))),
	PseudoHeaders = #{
		method => Method,
		scheme => case Transport of
			gun_tls -> <<"https">>;
			gun_tls_proxy -> <<"https">>;
			gun_tcp -> <<"http">>
		end,
		authority => Authority,
		path => Path
	},
	{ok, PseudoHeaders, Headers}.

data(State=#http2_state{http2_machine=HTTP2Machine}, StreamRef, ReplyTo, IsFin, Data) ->
	case get_stream_by_ref(State, StreamRef) of
		#stream{id=StreamID} ->
			case cow_http2_machine:get_stream_local_state(StreamID, HTTP2Machine) of
				{ok, fin, _} ->
					error_stream_closed(State, StreamRef, ReplyTo);
				{ok, _, fin} ->
					error_stream_closed(State, StreamRef, ReplyTo);
				{ok, _, _} ->
					maybe_send_data(State, StreamID, IsFin, Data)
			end;
		error ->
			error_stream_not_found(State, StreamRef, ReplyTo)
	end.

maybe_send_data(State=#http2_state{http2_machine=HTTP2Machine0}, StreamID, IsFin, Data0) ->
	Data = case is_tuple(Data0) of
		false -> {data, Data0};
		true -> Data0
	end,
	case cow_http2_machine:send_or_queue_data(StreamID, HTTP2Machine0, IsFin, Data) of
		{ok, HTTP2Machine} ->
			State#http2_state{http2_machine=HTTP2Machine};
		{send, SendData, HTTP2Machine} ->
			send_data(State#http2_state{http2_machine=HTTP2Machine}, SendData)
	end.

send_data(State, []) ->
	State;
send_data(State0, [{StreamID, IsFin, SendData}|Tail]) ->
	State = send_data(State0, StreamID, IsFin, SendData),
	send_data(State, Tail).

send_data(State0, StreamID, IsFin, [Data]) ->
	State = send_data_frame(State0, StreamID, IsFin, Data),
	maybe_delete_stream(State, StreamID, local, IsFin);
send_data(State0, StreamID, IsFin, [Data|Tail]) ->
	State = send_data_frame(State0, StreamID, nofin, Data),
	send_data(State, StreamID, IsFin, Tail).

send_data_frame(State=#http2_state{socket=Socket, transport=Transport},
		StreamID, IsFin, {data, Data}) ->
	Transport:send(Socket, cow_http2:data(StreamID, IsFin, Data)),
	State;
%% @todo Uncomment this once sendfile is supported.
%send_data_frame(State=#http2_state{socket=Socket, transport=Transport},
%		StreamID, IsFin, {sendfile, Offset, Bytes, Path}) ->
%	Transport:send(Socket, cow_http2:data_header(StreamID, IsFin, Bytes)),
%	Transport:sendfile(Socket, Path, Offset, Bytes),
%	State;
%% The stream is terminated in cow_http2_machine:prepare_trailers.
send_data_frame(State=#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine0}, StreamID, nofin, {trailers, Trailers}) ->
	{ok, HeaderBlock, HTTP2Machine}
		= cow_http2_machine:prepare_trailers(StreamID, HTTP2Machine0, Trailers),
	Transport:send(Socket, cow_http2:headers(StreamID, fin, HeaderBlock)),
	State#http2_state{http2_machine=HTTP2Machine}.

reset_stream(State0=#http2_state{socket=Socket, transport=Transport},
		StreamID, StreamError={stream_error, Reason, _}) ->
	Transport:send(Socket, cow_http2:rst_stream(StreamID, Reason)),
	case take_stream(State0, StreamID) of
		{#stream{ref=StreamRef, reply_to=ReplyTo}, State} ->
			ReplyTo ! {gun_error, self(), StreamRef, StreamError},
			State;
		error ->
			State0
	end.

cancel(State=#http2_state{socket=Socket, transport=Transport, http2_machine=HTTP2Machine0},
		StreamRef, ReplyTo) ->
	case get_stream_by_ref(State, StreamRef) of
		#stream{id=StreamID} ->
			{ok, HTTP2Machine} = cow_http2_machine:reset_stream(StreamID, HTTP2Machine0),
			Transport:send(Socket, cow_http2:rst_stream(StreamID, cancel)),
			delete_stream(State#http2_state{http2_machine=HTTP2Machine}, StreamID);
		error ->
			error_stream_not_found(State, StreamRef, ReplyTo)
	end.

timeout(State=#http2_state{http2_machine=HTTP2Machine0}, {cow_http2_machine, Name}, TRef) ->
	case cow_http2_machine:timeout(Name, TRef, HTTP2Machine0) of
		{ok, HTTP2Machine} ->
			{state, State#http2_state{http2_machine=HTTP2Machine}};
		{error, Error={connection_error, _, _}, _HTTP2Machine} ->
			connection_error(State, Error)
	end.

stream_info(State, StreamRef) ->
	case get_stream_by_ref(State, StreamRef) of
		#stream{reply_to=ReplyTo} ->
			{ok, #{
				ref => StreamRef,
				reply_to => ReplyTo,
				state => running
			}};
		error ->
			{ok, undefined}
	end.

down(#http2_state{stream_refs=Refs}) ->
	maps:keys(Refs).

connection_error(#http2_state{socket=Socket, transport=Transport,
		http2_machine=HTTP2Machine, streams=Streams},
		Error={connection_error, Reason, HumanReadable}) ->
	Pids = lists:usort(maps:fold(
		fun(_, #stream{reply_to=ReplyTo}, Acc) -> [ReplyTo|Acc] end,
		[], Streams)),
	_ = [Pid ! {gun_error, self(), {Reason, HumanReadable}} || Pid <- Pids],
	Transport:send(Socket, cow_http2:goaway(
		cow_http2_machine:get_last_streamid(HTTP2Machine),
		Reason, <<>>)),
	{error, Error}.

%% Stream functions.

error_stream_closed(State, StreamRef, ReplyTo) ->
	ReplyTo ! {gun_error, self(), StreamRef, {badstate,
		"The stream has already been closed."}},
	State.

error_stream_not_found(State, StreamRef, ReplyTo) ->
	ReplyTo ! {gun_error, self(), StreamRef, {badstate,
		"The stream cannot be found."}},
	State.

%% Streams.

get_stream_by_id(#http2_state{streams=Streams}, StreamID) ->
	maps:get(StreamID, Streams).

get_stream_by_ref(#http2_state{streams=Streams, stream_refs=Refs}, StreamRef) ->
	case maps:get(StreamRef, Refs, error) of
		error -> error;
		StreamID -> maps:get(StreamID, Streams)
	end.

create_stream(State=#http2_state{streams=Streams, stream_refs=Refs},
		Stream=#stream{id=StreamID, ref=StreamRef}) ->
	State#http2_state{
		streams=Streams#{StreamID => Stream},
		stream_refs=Refs#{StreamRef => StreamID}
	}.

store_stream(State=#http2_state{streams=Streams}, Stream=#stream{id=StreamID}) ->
	State#http2_state{streams=Streams#{StreamID => Stream}}.

take_stream(State=#http2_state{streams=Streams0, stream_refs=Refs}, StreamID) ->
	case maps:take(StreamID, Streams0) of
		{Stream=#stream{ref=StreamRef}, Streams} ->
			{Stream, State#http2_state{
				streams=Streams,
				stream_refs=maps:remove(StreamRef, Refs)
			}};
		error ->
			error
	end.

maybe_delete_stream(State=#http2_state{http2_machine=HTTP2Machine}, StreamID, local, fin) ->
	case cow_http2_machine:get_stream_remote_state(StreamID, HTTP2Machine) of
		{ok, fin} -> delete_stream(State, StreamID);
		{error, closed} -> delete_stream(State, StreamID);
		_ -> State
	end;
maybe_delete_stream(State=#http2_state{http2_machine=HTTP2Machine}, StreamID, remote, fin) ->
	case cow_http2_machine:get_stream_local_state(StreamID, HTTP2Machine) of
		{ok, fin, _} -> delete_stream(State, StreamID);
		{error, closed} -> delete_stream(State, StreamID);
		_ -> State
	end;
maybe_delete_stream(State, _, _, _) ->
	State.

delete_stream(State=#http2_state{streams=Streams, stream_refs=Refs}, StreamID) ->
	#{StreamID := #stream{ref=StreamRef}} = Streams,
	State#http2_state{
		streams=maps:remove(StreamID, Streams),
		stream_refs=maps:remove(StreamRef, Refs)
	}.

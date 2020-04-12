%% Copyright (c) 2015-2019, Loïc Hoguin <essen@ninenines.eu>
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

-module(gun_ws).

-export([check_options/1]).
-export([name/0]).
-export([opts_name/0]).
-export([has_keepalive/0]).
-export([default_keepalive/0]).
-export([init/4]).
-export([handle/2]).
-export([update_flow/4]).
-export([closing/2]).
-export([close/2]).
-export([keepalive/1]).
-export([ws_send/3]).
-export([down/1]).

-record(payload, {
	type = undefined :: cow_ws:frame_type(),
	rsv = undefined :: cow_ws:rsv(),
	len = undefined :: non_neg_integer(),
	mask_key = undefined :: cow_ws:mask_key(),
	close_code = undefined :: undefined | cow_ws:close_code(),
	unmasked = <<>> :: binary(),
	unmasked_len = 0 :: non_neg_integer()
}).

-record(ws_state, {
	reply_to :: pid(),
	stream_ref :: reference(),
	socket :: inet:socket() | ssl:sslsocket(),
	transport :: module(),
	opts = #{} :: gun:ws_opts(),
	buffer = <<>> :: binary(),
	in = head :: head | #payload{} | close,
	out = head :: head | close,
	frag_state = undefined :: cow_ws:frag_state(),
	utf8_state = 0 :: cow_ws:utf8_state(),
	extensions = #{} :: cow_ws:extensions(),
	flow :: integer() | infinity,
	handler :: module(),
	handler_state :: any()
}).

check_options(Opts) ->
	do_check_options(maps:to_list(Opts)).

do_check_options([]) ->
	ok;
do_check_options([{closing_timeout, infinity}|Opts]) ->
	do_check_options(Opts);
do_check_options([{closing_timeout, T}|Opts]) when is_integer(T), T > 0 ->
	do_check_options(Opts);
do_check_options([{compress, B}|Opts]) when B =:= true; B =:= false ->
	do_check_options(Opts);
do_check_options([{default_protocol, M}|Opts]) when is_atom(M) ->
	do_check_options(Opts);
do_check_options([{flow, InitialFlow}|Opts]) when is_integer(InitialFlow), InitialFlow > 0 ->
	do_check_options(Opts);
do_check_options([{keepalive, infinity}|Opts]) ->
	do_check_options(Opts);
do_check_options([{keepalive, K}|Opts]) when is_integer(K), K > 0 ->
	do_check_options(Opts);
do_check_options([Opt={protocols, L}|Opts]) when is_list(L) ->
	case lists:usort(lists:flatten([[is_binary(B), is_atom(M)] || {B, M} <- L])) of
		[true] -> do_check_options(Opts);
		_ -> {error, {options, {ws, Opt}}}
	end;
do_check_options([{reply_to, P}|Opts]) when is_pid(P) ->
	do_check_options(Opts);
do_check_options([{silence_pings, B}|Opts]) when B =:= true; B =:= false ->
	do_check_options(Opts);
do_check_options([{user_opts, _}|Opts]) ->
	do_check_options(Opts);
do_check_options([Opt|_]) ->
	{error, {options, {ws, Opt}}}.

name() -> ws.
opts_name() -> ws_opts.
has_keepalive() -> true.
default_keepalive() -> 5000.

init(ReplyTo, Socket, Transport, #{stream_ref := StreamRef, headers := Headers,
		extensions := Extensions, flow := InitialFlow, handler := Handler, opts := Opts}) ->
	{ok, HandlerState} = Handler:init(ReplyTo, StreamRef, Headers, Opts),
	{connected_ws_only, #ws_state{reply_to=ReplyTo, stream_ref=StreamRef,
		socket=Socket, transport=Transport, opts=Opts, extensions=Extensions,
		flow=InitialFlow, handler=Handler, handler_state=HandlerState}}.

%% Do not handle anything if we received a close frame.
%% Initiate or terminate the closing state depending on whether we sent a close yet.
handle(_, State=#ws_state{in=close, out=close}) ->
	[{state, State}, close];
handle(_, State=#ws_state{in=close}) ->
	closing(normal, State);
%% Shortcut for common case when Data is empty after processing a frame.
handle(<<>>, State=#ws_state{in=head}) ->
	maybe_active(State);
handle(Data, State=#ws_state{buffer=Buffer,
		in=head, frag_state=FragState, extensions=Extensions}) ->
	%% Send the event only if there was no data in the buffer.
	%% If there is data in the buffer then we already sent the event.
	Data2 = << Buffer/binary, Data/binary >>,
	case cow_ws:parse_header(Data2, Extensions, FragState) of
		{Type, FragState2, Rsv, Len, MaskKey, Rest} ->
			handle(Rest, State#ws_state{buffer= <<>>,
				in=#payload{type=Type, rsv=Rsv, len=Len, mask_key=MaskKey},
				frag_state=FragState2});
		more ->
			maybe_active(State#ws_state{buffer=Data2});
		error ->
			closing({error, badframe}, State)
	end;
handle(Data, State=#ws_state{in=In=#payload{type=Type, rsv=Rsv, len=Len, mask_key=MaskKey,
		close_code=CloseCode, unmasked=Unmasked, unmasked_len=UnmaskedLen}, frag_state=FragState,
		utf8_state=Utf8State, extensions=Extensions}) ->
	case cow_ws:parse_payload(Data, MaskKey, Utf8State, UnmaskedLen, Type, Len, FragState, Extensions, Rsv) of
		{ok, CloseCode2, Payload, Utf8State2, Rest} ->
			dispatch(Rest, State#ws_state{in=head, utf8_state=Utf8State2}, Type,
				<<Unmasked/binary, Payload/binary>>, CloseCode2);
		{ok, Payload, Utf8State2, Rest} ->
			dispatch(Rest, State#ws_state{in=head, utf8_state=Utf8State2}, Type,
				<<Unmasked/binary, Payload/binary>>, CloseCode);
		{more, CloseCode2, Payload, Utf8State2} ->
			maybe_active(State#ws_state{in=In#payload{close_code=CloseCode2,
				unmasked= <<Unmasked/binary, Payload/binary>>,
				len=Len - byte_size(Data), unmasked_len=2 + byte_size(Data)}, utf8_state=Utf8State2});
		{more, Payload, Utf8State2} ->
			maybe_active(State#ws_state{in=In#payload{unmasked= <<Unmasked/binary, Payload/binary>>,
				len=Len - byte_size(Data), unmasked_len=UnmaskedLen + byte_size(Data)}, utf8_state=Utf8State2});
		Error = {error, _Reason} ->
			closing(Error, State)
	end.

maybe_active(State=#ws_state{flow=Flow}) ->
	[
		{state, State},
		{active, Flow > 0}
	].

dispatch(Rest, State0=#ws_state{reply_to=ReplyTo,
		frag_state=FragState, flow=Flow0,
		handler=Handler, handler_state=HandlerState0},
		Type, Payload, CloseCode) ->
	case cow_ws:make_frame(Type, Payload, CloseCode, FragState) of
		Frame ->
			{ok, Dec, HandlerState} = Handler:handle(Frame, HandlerState0),
			Flow = case Flow0 of
				infinity -> infinity;
				_ -> Flow0 - Dec
			end,
			State1 = State0#ws_state{flow=Flow, handler_state=HandlerState},
			State = case Frame of
				ping ->
					[] = send(pong, State1, ReplyTo),
					State1;
				{ping, Payload} ->
					[] = send({pong, Payload}, State1, ReplyTo),
					State1;
				close ->
					State1#ws_state{in=close};
				{close, _, _} ->
					State1#ws_state{in=close};
				{fragment, fin, _, _} ->
					State1#ws_state{frag_state=undefined};
				_ ->
					State1
			end,
			handle(Rest, State)
	end.

update_flow(State=#ws_state{flow=Flow0}, _ReplyTo, _StreamRef, Inc) ->
	Flow = case Flow0 of
		infinity -> infinity;
		_ -> Flow0 + Inc
	end,
	[
		{state, State#ws_state{flow=Flow}},
		{active, Flow > 0}
	].

%% The user already sent the close frame; do nothing.
closing(_, State=#ws_state{out=close}) ->
	closing(State);
closing(Reason, State=#ws_state{reply_to=ReplyTo}) ->
	Code = case Reason of
		normal -> 1000;
		owner_down -> 1001;
		shutdown -> 1001;
		{error, badframe} -> 1002;
		{error, badencoding} -> 1007
	end,
	send({close, Code, <<>>}, State, ReplyTo).

closing(#ws_state{opts=Opts}) ->
	Timeout = maps:get(closing_timeout, Opts, 15000),
	{closing, Timeout}.

close(_, _State) ->
	ok.

keepalive(State=#ws_state{reply_to=ReplyTo}) ->
	[] = send(ping, State, ReplyTo),
	State.

%% Send one frame.
send(Frame, State=#ws_state{socket=Socket, transport=Transport, in=In, extensions=Extensions}, _ReplyTo) ->
	Transport:send(Socket, cow_ws:masked_frame(Frame, Extensions)),
	if
		Frame =:= close; element(1, Frame) =:= close ->
			[
				{state, State#ws_state{out=close}},
				%% We can close immediately if we already received a close frame.
				case In of
					close -> close;
					_ -> closing(State)
				end
			];
		true ->
			[]
	end.

%% Send many frames.
ws_send(Frame, State, ReplyTo) when not is_list(Frame) ->
	send(Frame, State, ReplyTo);
ws_send([], _, _) ->
	[];
ws_send([Frame|Tail], State, ReplyTo) ->
	case send(Frame, State, ReplyTo) of
		[] ->
			ws_send(Tail, State, ReplyTo);
		Other ->
			Other
	end.

%% Websocket has no concept of streams.
down(_) ->
	[].

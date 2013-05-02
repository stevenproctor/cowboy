%% Copyright (c) 2013, Loïc Hoguin <essen@ninenines.eu>
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

%% @doc SPDY protocol handler.
%%
%% The available options are:
%% <dl>
%% </dl>
%%
%% Note that there is no need to monitor these processes when using Cowboy as
%% an application as it already supervises them under the listener supervisor.
-module(cowboy_spdy).

%% API.
-export([start_link/4]).

%% Internal.
-export([init/4]).
-export([request_init/9]).
-export([resume/5]).
-export([reply/4]).
-export([stream_reply/3]).
-export([stream_data/2]).
-export([stream_close/1]).

%% Internal transport functions.
-export([name/0]).
-export([send/2]).

-record(child, {
	pid :: pid(),
	input = nofin :: fin | nofin,
	output = nofin :: fin | nofin
}).

-record(state, {
	socket,
	transport,
	middlewares,
	env,
	onrequest,
	onresponse,
	peer,
	zdef,
	zinf,
	children = [] :: [#child{}]
}).

-record(special_headers, {
	method,
	path,
	version,
	host,
	scheme %% @todo useful?
}).

-include("cowboy_spdy.hrl").

%% API.

%% @doc Start a SPDY protocol process.
-spec start_link(any(), inet:socket(), module(), any()) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
	%% @todo Parent, proc_lib
	Pid = spawn_link(?MODULE, init, [Ref, Socket, Transport, Opts]),
	{ok, Pid}.

%% Internal.

%% @doc Faster alternative to proplists:get_value/3.
%% @private
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.

%% @private
-spec init(any(), inet:socket(), module(), any()) -> ok.
init(Ref, Socket, Transport, Opts) ->
	%% @todo trap_exit
	{ok, Peer} = Transport:peername(Socket),
	Middlewares = get_value(middlewares, Opts, [cowboy_router, cowboy_handler]),
	Env = [{listener, Ref}|get_value(env, Opts, [])],
	OnRequest = get_value(onrequest, Opts, undefined),
	OnResponse = get_value(onresponse, Opts, undefined),
	Zdef = zlib:open(),
	ok = zlib:deflateInit(Zdef),
	_ = zlib:deflateSetDictionary(Zdef, ?ZDICT),
	Zinf = zlib:open(),
	ok = zlib:inflateInit(Zinf),
	ok = ranch:accept_ack(Ref),
	loop(#state{socket=Socket, transport=Transport,
		middlewares=Middlewares, env=Env, onrequest=OnRequest,
		onresponse=OnResponse, peer=Peer, zdef=Zdef, zinf=Zinf}).

%% @todo We don't want to kill all requests just because the
%% connection is gone. Perhaps leave some time for them to
%% finish or something.
loop(State=#state{socket=Socket, transport=Transport}) ->
	{OK, Closed, Error} = Transport:messages(),
	Transport:setopts(Socket, [{active, once}]),
	receive
		%% @todo We need to cut packets.
		{OK, Socket, Data = << _:40, Length:24, _/bits >>}
				when byte_size(Data) =:= Length + 8 ->
			control_frame(State, Data);
		{Closed, Socket} ->
			ok;
		{Error, Socket, _Reason} ->
			ok;
		{reply, {Pid, StreamID}, Status, Headers}
				when Pid =:= self() ->
			syn_reply(State, fin, StreamID, Status, Headers),
			loop(State);
		{reply, {Pid, StreamID}, Status, Headers, Body}
				when Pid =:= self() ->
			syn_reply(State, nofin, StreamID, Status, Headers),
			data(State, fin, StreamID, Body),
			loop(State);
		{stream_reply, {Pid, StreamID}, Status, Headers}
				when Pid =:= self() ->
			syn_reply(State, nofin, StreamID, Status, Headers),
			loop(State);
		{stream_data, {Pid, StreamID}, Data}
				when Pid =:= self() ->
			data(State, nofin, StreamID, Data),
			loop(State);
		{stream_close, {Pid, StreamID}}
				when Pid =:= self() ->
			data(State, fin, StreamID),
			loop(State)
	after 60000 ->
		ok
	end.

%% We do not support SYN_STREAM with FLAG_UNIDIRECTIONAL set.
control_frame(State, << _:38, 1:1, _:26, StreamID:31, _/bits >>) ->
	rst_stream(State, StreamID, internal_error),
	loop(State);
%% We do not support Associated-To-Stream-ID and CREDENTIAL Slot.
control_frame(State, << _:65, StreamID:31, _:1, AssocToStreamID:31,
		_:8, Slot:8, _/bits >>) when AssocToStreamID =/= 0; Slot =/= 0 ->
	rst_stream(State, StreamID, internal_error),
	loop(State);
%% SYN_STREAM
%%
%% Erlang does not allow us to control the priority of processes
%% so we ignore that value entirely.
control_frame(State=#state{middlewares=Middlewares, env=Env,
		onrequest=OnRequest, onresponse=OnResponse, peer=Peer, zinf=Zinf},
		<< 1:1, 3:15, 1:16, _Flags:8, _:25, StreamID:31,
		_:32, _Priority:3, _:13, Rest/bits >>) ->
	%% @todo We probably want to note if it's fin or nofin for later.
	[<< NbHeaders:32, Rest2/bits >>] = try
		zlib:inflate(Zinf, Rest)
	catch _:_ ->
		ok = zlib:inflateSetDictionary(Zinf, ?ZDICT),
		zlib:inflate(Zinf, <<>>)
	end,
	case syn_stream_headers(Rest2, NbHeaders, [], #special_headers{}) of
		{ok, Headers, Special} ->
			%% @todo Add to children, save nofin|fin depending on Flags
			_ = spawn_link(?MODULE, request_init,
				[self(), StreamID, Peer, Headers,
				OnRequest, OnResponse, Env, Middlewares, Special]);
		{error, special} ->
			rst_stream(State, StreamID, protocol_error)
	end,
	loop(State);
%% SYN_REPLY
control_frame(State, << 1:1, 3:15, 2:16, _Flags:8, _Length:24, _/bits >>) ->
	error_logger:error_msg("Ignored SYN_REPLY control frame~n"),
	loop(State);
%% RST_STREAM
control_frame(_State, << 1:1, 3:15, 3:16, Flags:8, Length:24, Rest/bits >>) ->
	%% @todo We probably want to handle this one.
	io:format("RST_STREAM ~p ~p ~p~n", [Flags, Length, Rest]);
%% SETTINGS
control_frame(State, << 1:1, 3:15, 4:16, 0:8, _:24,
		NbEntries:32, Rest/bits >>) ->
	%% @todo Handle this if possible.
	Settings = [{Flags, ID, Value} || << Flags:8, ID:24, Value:32 >> <= Rest],
	NbEntries = length(Settings), %% @todo PROTOCOL_ERROR if number doesn't match
	io:format("SETTINGS ~p~n", [Settings]),
	loop(State);
%% PING
control_frame(_State, << 1:1, 3:15, 6:16, Flags:8, Length:24, Rest/bits >>) ->
	%% @todo We probably want to handle this one.
	io:format("PING ~p ~p ~p~n", [Flags, Length, Rest]);
%% GOAWAY
control_frame(State, << 1:1, 3:15, 7:16, _Flags:8, _Length:24, _/bits >>) ->
	error_logger:error_msg("Ignored GOAWAY control frame~n"),
	loop(State);
%% HEADERS
control_frame(State, << 1:1, 3:15, 8:16, _Flags:8, _Length:24, _/bits >>) ->
	error_logger:error_msg("Ignored HEADERS control frame~n"),
	loop(State);
%% WINDOW_UPDATE
control_frame(State, << 1:1, 3:15, 9:16, 0:8, _Length:24, _/bits >>) ->
	error_logger:error_msg("Ignored WINDOW_UPDATE control frame~n"),
	loop(State);
%% CREDENTIAL
control_frame(State, << 1:1, 3:15, 10:16, _Flags:8, _Length:24, _/bits >>) ->
	error_logger:error_msg("Ignored CREDENTIAL control frame~n"),
	loop(State);
%% ???
control_frame(_State, Buffer) ->
	rst_stream(State, StreamID, protocol_error),
	loop(State).

syn_stream_headers(<<>>, 0, Acc, Special=#special_headers{
		method=Method, path=Path, version=Version, host=Host, scheme=Scheme}) ->
	if Method =:= undefined; Path =:= undefined; Version =:= undefined;
		Host =:= undefined; Scheme =:= undefined ->
			{error, special};
		true ->
			{ok, lists:reverse(Acc), Special}
	end;
syn_stream_headers(<< NameLen:32, Rest/bits >>, NbHeaders, Acc, Special) ->
	<< Name:NameLen/binary, ValueLen:32, Rest2/bits >> = Rest,
	<< Value:ValueLen/binary, Rest3/bits >> = Rest2,
	case Name of
		<<":host">> ->
			syn_stream_headers(Rest3, NbHeaders - 1,
				[{<<"host">>, Value}|Acc],
				Special#special_headers{host=Value});
		<<":method">> ->
			syn_stream_headers(Rest3, NbHeaders - 1, Acc,
				Special#special_headers{method=Value});
		<<":path">> ->
			syn_stream_headers(Rest3, NbHeaders - 1, Acc,
				Special#special_headers{path=Value});
		<<":version">> ->
			syn_stream_headers(Rest3, NbHeaders - 1, Acc,
				Special#special_headers{version=Value});
		<<":scheme">> ->
			syn_stream_headers(Rest3, NbHeaders - 1, Acc,
				Special#special_headers{scheme=Value});
		_ ->
			syn_stream_headers(Rest3, NbHeaders - 1,
				[{Name, Value}|Acc], Special)
	end.

syn_reply(#state{socket=Socket, transport=Transport, zdef=Zdef},
		IsFin, StreamID, Status, Headers) ->
	Headers2 = [{<<":status">>, Status},
		{<<":version">>, <<"HTTP/1.1">>}|Headers],
	NbHeaders = length(Headers2),
	HeaderBlock = [begin
		NameLen = byte_size(Name),
		ValueLen = iolist_size(Value),
		[<< NameLen:32, Name/binary, ValueLen:32 >>, Value]
	end || {Name, Value} <- Headers2],
	HeaderBlock2 = [<< NbHeaders:32 >>, HeaderBlock],
	HeaderBlock3 = zlib:deflate(Zdef, HeaderBlock2, full),
	Flags = case IsFin of
		fin -> 1;
		nofin -> 0
	end,
	Len = 4 + iolist_size(HeaderBlock3),
	Transport:send(Socket, [
		<< 1:1, 3:15, 2:16, Flags:8, Len:24, 0:1, StreamID:31 >>,
		HeaderBlock3]).

rst_stream(#state{socket=Socket, transport=Transport}, StreamID, Status) ->
	StatusCode = case Status of
		protocol_error -> 1;
		invalid_stream -> 2;
		refused_stream -> 3;
		unsupported_version -> 4;
		cancel -> 5;
		internal_error -> 6;
		flow_control_error -> 7;
		stream_in_use -> 8;
		stream_already_closed -> 9;
		invalid_credentials -> 10;
		frame_too_large -> 11
	end,
	Transport:send(Socket, << 1:1, 3:15, 3:16, 0:8, 8:24,
		0:1, StreamID:31, StatusCode:32 >>).

data(#state{socket=Socket, transport=Transport}, fin, StreamID) ->
	Transport:send(Socket, << 0:1, StreamID:31, 1:8, 0:24 >>).

data(#state{socket=Socket, transport=Transport}, IsFin, StreamID, Data) ->
	Flags = case IsFin of
		fin -> 1;
		nofin -> 0
	end,
	Len = iolist_size(Data),
	Transport:send(Socket, [
		<< 0:1, StreamID:31, Flags:8, Len:24 >>,
		Data]).

%% Request process.

request_init(Parent, StreamID, Peer,
		Headers, OnRequest, OnResponse, Env, Middlewares,
		#special_headers{method=Method, path=Path, version=Version,
		host=Host}) ->
	Version2 = parse_version(Version),
	{Host2, Port} = cowboy_protocol:parse_host(Host, <<>>),
	{Path2, Query, Fragment} = parse_path(Path, <<>>),
	Req = cowboy_req:new({Parent, StreamID}, ?MODULE, Peer,
		Method, Path2, Query, Fragment, Version2, Headers,
		Host2, Port, <<>>, true, false, OnResponse),
	case OnRequest of
		undefined ->
			execute(Req, Env, Middlewares);
		_ ->
			Req2 = OnRequest(Req),
			case cowboy_req:get(resp_state, Req2) of
				waiting -> execute(Req2, Env, Middlewares);
				_ -> ok
			end
	end.

parse_version(<<"HTTP/1.1">>) ->
	{1, 1};
parse_version(<<"HTTP/1.0">>) ->
	{1, 0}.

parse_path(<<>>, Path) ->
	{Path, <<>>, <<>>};
parse_path(<< $?, Rest/binary >>, Path) ->
	parse_query(Rest, Path, <<>>);
parse_path(<< $#, Fragment/binary >>, Path) ->
	{Path, <<>>, Fragment};
parse_path(<< C, Rest/binary >>, SoFar) ->
	parse_path(Rest, << SoFar/binary, C >>).

parse_query(<<>>, Path, Query) ->
	{Path, Query, <<>>};
parse_query(<< $#, Fragment/binary >>, Path, Query) ->
	{Path, Query, Fragment};
parse_query(<< C, Rest/binary >>, Path, SoFar) ->
	parse_query(Rest, Path, << SoFar/binary, C >>).

-spec execute(cowboy_req:req(), cowboy_middleware:env(), [module()])
	-> ok.
execute(Req, _, []) ->
	cowboy_req:ensure_response(Req, 204);
execute(Req, Env, [Middleware|Tail]) ->
	case Middleware:execute(Req, Env) of
		{ok, Req2, Env2} ->
			execute(Req2, Env2, Tail);
		{suspend, Module, Function, Args} ->
			erlang:hibernate(?MODULE, resume,
				[Env, Tail, Module, Function, Args]);
		{halt, Req2} ->
			cowboy_req:ensure_response(Req2, 204);
		{error, Code, Req2} ->
			error_terminate(Code, Req2)
	end.

%% @private
-spec resume(cowboy_middleware:env(), [module()],
	module(), module(), [any()]) -> ok.
resume(Env, Tail, Module, Function, Args) ->
	case apply(Module, Function, Args) of
		{ok, Req2, Env2} ->
			execute(Req2, Env2, Tail);
		{suspend, Module2, Function2, Args2} ->
			erlang:hibernate(?MODULE, resume,
				[Env, Tail, Module2, Function2, Args2]);
		{halt, Req2} ->
			cowboy_req:ensure_response(Req2, 204);
		{error, Code, Req2} ->
			error_terminate(Code, Req2)
	end.

%% Only send an error reply if there is no resp_sent message.
-spec error_terminate(cowboy_http:status(), cowboy_req:req()) -> ok.
error_terminate(Code, Req) ->
	receive
		{cowboy_req, resp_sent} -> ok
	after 0 ->
		_ = cowboy_req:reply(Code, Req),
		ok
	end.

%% Reply functions used by cowboy_req.

reply(Socket = {Pid, _}, Status, Headers, Body) ->
	_ = case iolist_size(Body) of
		0 -> Pid ! {reply, Socket, Status, Headers};
		_ -> Pid ! {reply, Socket, Status, Headers, Body}
	end,
	ok.

stream_reply(Socket = {Pid, _}, Status, Headers) ->
	_ = Pid ! {stream_reply, Socket, Status, Headers},
	ok.

stream_data(Socket = {Pid, _}, Data) ->
	_ = Pid ! {stream_data, Socket, Data},
	ok.

stream_close(Socket = {Pid, _}) ->
	_ = Pid ! {stream_close, Socket},
	ok.

%% Internal transport functions.

name() ->
	spdy.

send(Socket, Data) ->
	stream_data(Socket, Data).

%recv
%sendfile

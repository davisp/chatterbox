-module(h2_connection).
-include("http2.hrl").
-behaviour(gen_statem).

%% Start/Stop API
-export([
         start_client_link/5,
         become/3,
         stop/1
        ]).


-export([
    new_stream/2,
    new_stream/3,

    send_ping/1,
    send_window_update/2,
    update_settings/2,

    get_peer/1,
    get_peercert/1
]).

%% gen_statem callbacks
-export([
    init/1,
    terminate/3,
    callback_mode/0,
    code_change/4
]).

%% gen_statem states
-export([
    handshake/3,
    connected/3,
    continuation/3,
    closing/3
]).


-type stream_info() :: #{
    pid := undefined | pid(),
    send_window_size := non_neg_integer(),
    recv_window_size := non_neg_integer()
}.


-type streams() :: #{
    stream_id() => stream_info()
}.


-type continuation() :: #{
    stream_id := stream_id(),
    type := headers | push_promise,
    promised_id => stream_id(),
    frames := queue:queue(h2:frame()),
    end_headers := boolean(),
    end_stream := boolean()
}.


-record(connection, {
    type = undefined :: client | server | undefined,
    socket = undefined :: sock:socket(),

    send_settings = #settings{} :: settings(),
    recv_settings = #settings{} :: settings(),

    decode_context = hpack:new_context() :: hpack:context(),
    encode_context = hpack:new_context() :: hpack:context(),

    settings_sent = queue:new() :: queue:queue(),

    streams = h2_stream_set:new() :: h2:stream_set(),

    buffer = empty :: empty | {binary, binary()} | {frame, h2_frame:header(), binary()},
    continuation = undefined :: undefined | continuation(),

    flow_control = auto :: auto | manual,

    pings = #{} :: #{binary() => {pid(), non_neg_integer()}}
}).

-type connection() :: #connection{}.


-spec start_client_link(gen_tcp | ssl,
                        inet:ip_address() | inet:hostname(),
                        inet:port_number(),
                        [ssl:ssl_option()],
                        settings()
                       ) ->
                               {ok, pid()} | ignore | {error, term()}.
start_client_link(Transport, Host, Port, SSLOptions, Http2Settings) ->
    gen_statem:start_link(?MODULE, {client, Transport, Host, Port, SSLOptions, Http2Settings}, []).


-spec become(socket(), settings(), maps:map()) -> no_return().
become({Transport, Socket}, Http2Settings, ConnectionSettings) ->
    ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary]),
    case init({server, {Transport, Socket}, Http2Settings, Opts}) of
        {_, handshake, NewState} ->
            gen_statem:enter_loop(?MODULE, [], handshake, NewState);
        {_, closing, _NewState} ->
            sock:close({Transport, Socket}),
            exit(invalid_preface)
    end.


-spec new_stream(pid(), h2:headers()) -> {ok, stream()} | {error, term()}.
new_stream(ConnPid, Headers) ->
    gen_statem:call(ConnPid, {new_stream, self(), Headers, []}, infinity).


-spec new_stream(pid(), h2:headers(), [h2:send_opt() | h2:stream_opt()])
        -> {ok, stream()} | {error, term()}.
new_stream(ConnPid, Headers, Options) when is_list(Options) ->
    gen_statem:call(ConnPid, {new_stream, self(), Headers, Options}, infinity).


-spec send_ping(pid()) -> ok.
send_ping(Pid) ->
    gen_statem:call(Pid, {send_ping, self()}, infinity),
    ok.


-spec send_window_update(pid(), non_neg_integer()) -> ok.
send_window_update(Pid, Size) ->
    gen_statem:cast(Pid, {send_window_update, Size}).


-spec update_settings(pid(), h2_frame_settings:payload()) -> ok.
update_settings(Pid, Payload) ->
    gen_statem:cast(Pid, {update_settings, Payload}).


-spec get_peer(pid()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
get_peer(Pid) ->
    gen_statem:call(Pid, get_peer).


-spec get_peercert(pid()) ->
    {ok, binary()} | {error, term()}.
get_peercert(Pid) ->
    gen_statem:call(Pid, get_peercert).


-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:cast(Pid, stop).


%% Init callback
init({client, Transport, Host, Port, SSLOptions, Http2Settings}) ->
    case Transport:connect(Host, Port, client_options(Transport, SSLOptions)) of
        {ok, Socket} ->
            init({client, {Transport, Socket}, Http2Settings});
        {error, Reason} ->
            {stop, Reason}
    end;
init({client, {Transport, Socket}, Http2Settings}) ->
    ok = sock:setopts({Transport, Socket}, [{packet, raw}, binary, {active, once}]),
    Transport:send(Socket, <<?PREFACE>>),
    InitialState = #connection{
        type = client,
        socket = {Transport, Socket},
        streams = h2_stream_set:new(client, #settings{}, #settings{}),
        next_available_stream_id = 1,
        flow_control = auto
    },
    {ok, handshake, send_settings(Http2Settings, InitialState), 4500};
init({server, {_T, _S} = Socket, Http2Settings}) ->
    case accept_preface(Socket) of
        ok ->
            ok = active_once(Socket),
            InitialState = #connection{
                type = server,
                socket = Socket,,
                streams = h2_stream_set:new(server, #settings{}, #settings{}),
                flow_control = auto
            },
            {next_state, handshake, send_settings(Http2Settings, InitialState)};
        {error, invalid_preface} ->
            {next_state, closing, Conn}
    end.


terminate(_Reason, _StateName, _Conn) ->
    ok.


callback_mode() ->
    state_functions.


code_change(_OldVsn, StateName, Conn, _Extra) ->
    {ok, StateName, Conn}.


-spec handshake(gen_statem:event_type(), {frame, h2_frame:frame()} | term(), connection()) ->
                    {next_state,
                     handshake|connected|closing,
                     connection()}.
handshake(timeout, _, Conn) ->
    go_away(?PROTOCOL_ERROR, Conn);
handshake(_, {frame, #frame{type = ?SETTINGS}}, Conn) ->
    %% The first frame should be the client settings as per
    %% RFC-7540#3.5
    handle_frame(Frame, Conn);
handshake(_, {frame, _Frame}, Conn) ->
    go_away(?PROTOCOL_ERROR, Conn);
handshake(Type, Msg, Conn) ->
    handle_ev(Type, Msg, Conn).

connected(_, {frame, Frame}, #connection{}=Conn) ->
    handle_frame(Frame, Conn);
connected(Type, Msg, State) ->
    handle_ev(Type, Msg, State).

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
continuation(_, {frame, #frame{type = Type} = Frame}, #connetion{} = Conn)
        when Type == ?CONTINUATION ->
    #frame{
        stream_id = StreamId
    } = Frame,
    #connection{
        continuation = #{
            stream_id := ContStreamId
        }
    } = Conn,
    case ContStreamId == StreamId of
        true ->
            handle_frame(Frame, Conn);
        false ->
            go_away(?PROTOCOL_ERROR, Conn)
    end;
continuation(Type, Msg, State) ->
    handle_ev(Type, Msg, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.
closing(_, _Message, #connection{} = Conn) ->
    #connection{
        socket = Socket
    } = Conn,
    sock:close(Socket),
    {stop, normal, Conn};
closing(Type, Msg, State) ->
    handle_ev(Type, Msg, State).


handle_frame(Frame, Conn) ->
    #frame{
        length = Length
    } = Frame,
    #connection{
        recv_settings = #settings{
            max_frame_size = MaxFrameSize
        }
    } = Conn,

    try
        if Length =< MaxFrameSize -> ok; true ->
            ?CONN_ERROR(?FRAME_SIZE_ERROR)
        end,

        route_frame(Frame, Conn)
    catch
        throw:{h2_goaway, ErrorCode} ->
            go_away(ErrorCode, Conn);
        throw:{h2_stream_error, StreamId, ErrorCode} ->
            reset_stream(StreamId, ErrorCode, Conn)
    end.


handle_ev(Type, Msg, Conn) ->
    try
        handle_event(Type, Msg, Conn)
    catch
        throw:{h2_goaway, ErrorCode} ->
            go_away(ErrorCode, Conn);
        throw:{h2_stream_error, StreamId, ErrorCode} ->
            reset_stream(StreamId, ErrorCode, Conn)
    end.


%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (h2_stream:recv_frame)
-spec route_frame(h2:frame() | {error, term()}, connection()) ->
    {next_state, connected | continuation | closing, connection()}.


route_frame(#frame{type = Type, flags = Flags} = Frame, #connection{} = Conn)
        when Type == ?SETTINGS, ?NOT_FLAG(Flags, ?ACK) ->
    #frame{
        stream_id = StreamId,
        data = Settings
    } = Frame,
    #connection{
        peer_settings = OldSettings = #settings{
            initial_window_size = OldWindowSize,
            header_table_size = OldTableSize
        },
        streams = Streams1,
        encode_context = EncCtx
    } = Conn,

    if StreamId == 0 -> ok; true ->
        ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    case h2_settings:validate(Settings) of
        ok -> ok;
        {error, Code} -> ?CONN_ERROR(Code)
    end,

    NewSettings = h2_settings:merge(OldSettings, Settings),

    TableSize = NewSettings#settings.header_table_size,
    NewEncCtx = hpack:new_max_table_size(TableSize, EncCtx),

    Streams2 = h2_stream_set:set_send_settings(NewSettings),

    send_frames(Conn, h2_frame:settings_ack()),

    %% Why aren't we updating send_window_size here? Section 6.9.2 of
    %% the spec says: "The connection flow-control window can only be
    %% changed using WINDOW_UPDATE frames.",
    NewConn = Conn#connection{
        peer_settings = NewSettings,
        encode_context = NewEncCtx,
        streams = Streams2
    },

    {next_state, connected, NewConn};

route_frame(#frame{type = Type, flags = Flags} = Frame, #connection{} = Conn)
        when Type == ?SETTINGS, ?IS_FLAG(Flags, ?ACK) ->
    #frame {
        stream_id = StreamId
    } = Frame,
    #connection{
        settings_sent = SettingsSent,
        streams = Streams1,
        self_settings = #settings{
            initial_window_size = OldWindowSize
        }
    } = Conn,

    if StreamId == 0 -> ok; true ->
        ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    case queue:is_empty(SettingsSent) of
        true -> ?CONN_ERROR(?INTERNAL_ERROR);
        false -> ok
    end,

    {{value, {_Rev, NewSettings}}, NewSettingsSent} =
            queue:out(SettingsSent),

    Streams2 = h2_stream_set:set_recv_settings(Streams1, NewSettings),

    NewConn = Conn#connection{
        settings_sent = NewSettingsSent,
        self_settings = NewSettings,
        streams = Streams2
    },

    {next_state, connected, NewConn};

route_frame(#frame{type = ?DATA} = Frame, #connection{} = Conn) ->
    #frame{
        stream_id = StreamId,
    } = Frame,
    #connection{
        streams = Streams1,
        flow_control = FlowControl
    } = Conn,

    {Streams2, Frames} = h2_stream_set:handle_data(
            Streams1,
            StreamId,
            Frame,
            FlowControl
        ),

    send_frames(Conn, Frames),
    NewConn = Conn#connection{
        streams = Streams2
    },

    {keep_state, NewConn};

route_frame({#frame{type = ?HEADERS, stream_id = StreamId}, Conn)
        when Conn#connection.type == server, StreamId rem 2 == 0 ->
    ?CONN_ERROR(?PROTOCOL_ERROR);
route_frame({#frame{type = ?HEADERS} = Frame, #connection{} = Conn) ->
    #frame{
        flags = Flags,
        stream_id = StreamId
    } = Frame,
    #connection{
        type = ConnType,
        streams = Streams1
    } = Conn,

    Stream = h2_stream_set:get(StreamId, Streams),
    StreamType = h2_stream_set:type(Stream),

    case {ConnType, StreamType} of
        {server, idle} ->
            ok;
        {server, active} ->
            ok;
        {client, active} ->
            ok;
        _ ->
            ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    Cont = #{
        stream_id => StreamId,
        type => ContinuationType,
        frames => queue:from_list([Frame]),
        end_headers => ?IS_FLAG(Flags, ?END_HEADERS),
        end_stream => ?IS_FLAG(Flags, ?END_STREAM)
    },
    handle_continuation(Cont, NewConn);

route_frame(#frame{type = ?CONTINUATION} = Frame, Conn) ->
    #frames{
        flags = Flags
    } = Frame,
    #connection{
        continuation = Cont = #{
            frames := FrameQueue
        }
    } = Conn,
    NewCont = Cont#{
        frames := queue:in(Frame, FrameQueue),
        end_headers := ?IS_FLAG(Flags, ?END_HEADERS)
    },
    handle_continuation(NewCont, Conn);

route_frame(#frame{type = ?PRIORITY, stream_id = 0}, Conn) ->
    ?CONN_ERROR(?PROTOCOL_ERROR);
route_frame(#frame{type = ?PRIORITY} = Frame, Conn) ->
    {next_state, connected, Conn};

route_frame(#frame{type = ?RST_STREAM} = Frame, Conn) ->
    #frame{
        data = ErrorCode
    } = Frame,
    #connection{
        streams = Streams1
    } = Conn,
    Streams2 = h2_stream_set:reset(Streams1, StreamId),
    NewConn = Conn#connection{
        streams = Streams2
    },
    {keep_state, NewConn};

route_frame(#frame{type = ?PUSH_PROMISE}, Conn) ->
        when Conn#connection.type == server ->
    ?CONN_ERROR(?PROTOCOL_ERROR);
route_frame(#frame{type = ?PUSH_PROMISE} = Frame, Conn) ->
        when Conn#connection.type == client ->
    #frame{
        stream_id = StreamId,
        data = {PromisedStreamId, _}
    } = Frame,
    Cont = #{
        stream_id => StreamId,
        type => push_promise,
        promised_id => PromisedStreamId
        frames => queue:from_list([Frame]),
        end_headers => ?IS_FLAG(Flags, ?END_HEADERS),
        end_stream => false
    },
    handle_continuation(Cont, Conn);

route_frame(#frame{type = ?PING, stream_id = 0} = Frame, Conn) ->
    #frame{
        flags = Flags,
        data = Data
    } = Frame,
    #connection{
        pings = Pings
    } = Conn,
    NewPings = case ?IS_FLAG(Flags, ?ACK) of
        true ->
            Pid = maps:get(Data, Pings),
            Pid ! {'PONG', self()},
            maps:remove(Data, Pings);
        false ->
            Ack = h2_frame:ping_ack(Data),
            send_frames(Conn, [Ack]),
            Pings
    end;
    NewConn#connection{
        pings = NewPings
    },
    {next_state, connected, NewConn};

route_frame(#frame{type = ?GOAWAY} = Frame, Conn) ->
    #frame{
        data = {_LastStreamId, ErrorCode, _Debug}
    },
    ?CONN_ERROR(ErrorCode, Conn);

route_frame(#frame{type = ?WINDOW_UPDATE}, Conn) ->
    #frame{
        stream_id = StreamId,
        data = Increment
    } = Frame,
    #connection{
        streams = Streams1
    } = Conn,

    {Streams2, Frames} = h2_stream_set:handle_send_window_update(
            Streams1,
            StreamId,
            Increment
        ),

    Streams3 = h2_streams:flush(Streams2),

    send_frames(Conn, Frames),
    NewConn = Conn#connection{
        streams = Streams2
    },
    {keep_state, NewConn};

route_frame(#frame{type = Type}, Conn) when Type > ?CONTINUATION ->
    {next_state, connected, Conn};

route_frame(Frame, Conn) ->
    Msg = "Frame condition not covered by pattern match."
            "Please open a github issue with this output: ~s",
    error_logger:error_msg(Msg, [h2_frame:format(Frame)]),
    go_away(?PROTOCOL_ERROR, Conn).



handle_event({call, From}, {new_stream, Pid, Headers, Opts}, Conn)
        when Conn#connection.type == client ->
    #connection{
        encode_context = EncCtx,
        send_settings = #settings{
            max_frame_size = MaxFrameSize
        },
        streams = Streams1
    } = Conn,

    case h2_stream_set:new_stream(Streams1, Pid, Opts) of
        {ok, Streams2, StreamId} ->
            EndStream = case proplists:get_value(end_stream, Opts) of
                true -> true;
                _ -> false
            end,
            {Frames, NewEncCtx} = h2_headers:to_frames(
                    Headers,
                    EncCtx,
                    MaxFrameSize,
                    EndStream
                ),
            send_frames(Conn, Frames),
            NewConn = Conn#connection{
                encode_context = NewEncCtx,
                streams = NewStreams
            },
            Stream = #{
                id => StreamId,
                pid => self()
            },
            {keep_state, NewConn, [{reply, From, {ok, Stream}}]};
        {error, Reason} ->
            {keep_state, Conn, [{reply, From, {error, Reason}}]}
    end;


handle_event({call, From}, {stream_send, StreamId, Data, Opts}, Conn) ->
    #connection{
        streams = Streams1
    } = Conn,

    case h2_stream_set:queue(Streams, StreamId, Data, Opts) of
        {ok, Streams2} ->
            {ok, Streams3, Frames} = h2_stream_set:flush(Streams2, StreamId),
            send_frames(Conn, Frames),
            NewConn = Conn#connection{
                streams = Streams3
            },
            {keep_state, NewConn, [{reply, From, ok}]};
        {error, _} = Error ->
            {keep_state, NewConn, [{reply, From, Error}]}
    end;

handle_event({call, From}, {recv_window_update, StreamId, Increment}, Conn) ->
    h2_stream_set:handle_recv_window_update(Streams, StreamId, Increment),

handle_event({call, From}, {send_ping, NotifyPid}, Conn) ->
    #connection{
        pings = Pings
    } = Conn,

    PingValue = crypto:strong_rand_bytes(8),
    Frame = h2_frame:ping(PingValue),

    case send_frames(Conn, [Frame]) of
        ok ->
            PingRespInfo = {NotifyPid, erlang:monotonic_time(milli_seconds)},
            NewPings = maps:put(PingValue, PingRespInfo, Pings),
            NewConn = Conn#connection{pings = NextPings},
            {keep_state, NextConn, [{reply, From, ok}]};
        {error, _Reason} = Error ->
            {keep_state, Conn, [{reply, From, Error}]}
    end;

handle_event(_, {update_settings, Http2Settings}, Conn) ->
    {keep_state, send_settings(Http2Settings, Conn)};

handle_event(_, {check_settings_ack, {Ref, NewSettings}}, Conn) ->
    #connection{
        settings_sent = SettingsSent
    } = Conn,
    case queue:out(SettingsSent) of
        {{value, {Ref, NewSettings}}, _} ->
            go_away(?SETTINGS_TIMEOUT, Conn);
        _ ->
            {keep_state, Conn}
    end;

handle_event({call, From}, get_peer, Conn) ->
    #connection{
        socket = Socket
    } = Conn,
    case sock:peername(Socket) of
        {ok, _AddrPort} = OK ->
            {keep_state, Conn, [{reply, From, OK}]};
        {error, _} = Error ->
            {keep_state, Conn, [{reply, From, Error}]}
    end;

handle_event({call, From}, get_peercert, Conn) ->
    #connection{
        socket = Socket
    } = Conn,
    case sock:peercert(Socket) of
        {ok, _Cert} = OK ->
            {keep_state, Conn, [{reply, From, OK}]};
        {error, _} = Error ->
            {keep_state, Conn, [{reply, From, Error}]}
    end;

%% Socket Messages
handle_event(info, {tcp, Socket, Data}, Conn)
        when Conn#connection.socket == {gen_tcp, Socket} ->
    handle_socket_data(Data, Conn);
handle_event(info, {tcp_passive, Socket}, Conn)
        when Conn#connection.socket == {gen_tcp, Socket} ->
    handle_socket_passive(Conn);
handle_event(info, {tcp_closed, Socket}, Conn)
        when Conn#connection.socket == {gen_tcp, Socket} ->
    handle_socket_closed(Conn);
handle_event(info, {tcp_error, Socket, Reason}, Conn) ->
        when Conn#connection.socket == {gen_tcp, Socket} ->
    handle_socket_error(Reason, Conn);

handle_event(info, {ssl, Socket, Data}, Conn)
        when Conn#connection.socket == {ssl, Socket} ->
    handle_socket_data(Data, Conn);
handle_event(info, {ssl_closed, Socket}, Conn)
        when Conn#connection.socket == {ssl, Socket} ->
    handle_socket_closed(Conn);
handle_event(info, {ssl_error, Socket, Reason}, Conn)
        when Conn#connection.socket == {ssl, Socket} ->
    handle_socket_error(Reason, Conn);

handle_event(info, {_, R}, #connection{} = Conn) ->
    handle_socket_error(R, Conn);

handle_event(_, _, Conn) ->
     go_away(?PROTOCOL_ERROR, Conn).


-spec go_away(error_code(), connection()) -> {next_state, closing, connection()}.
go_away(ErrorCode, Conn) ->
    #connection{
        streams = Streams
    } = Conn,
    NextStreamId = h2_stream_set:local_next_id(Streams)
    GoAway = h2_frame:goaway(NextStreamId, ErrorCode),
    send_frame(Conn, GoAway),
    {next_state, closing, Conn}.


-spec send_settings(settings(), connection()) -> connection().
send_settings(SettingsToSend, Conn) ->
    #connection{
        recv_settings = CurrentSettings,
        settings_sent = SettingsSent
    } = Conn,

    Ref = make_ref(),
    Frame = h2_settings:frames(CurrentSettings, SettingsToSend),
    send_frame(Conn, Frame),
    send_ack_timeout({Ref, SettingsToSend}),
    Conn#connection{
        settings_sent = queue:in({Ref, SettingsToSend}, SettingsSent)
    }.


-spec send_ack_timeout({reference(), settings()}) -> pid().
send_ack_timeout(SettingsInfo) ->
    erlang:send_after(self(), 5000, {check_settings_ack, SettingsINfo}).


active_once(Socket) ->
    sock:setopts(Socket, [{active, once}]).


client_options(Transport, SSLOpts) ->
    SockOpts = [binary, {packet, raw}, {active, false}],
    case Transport of
        ssl ->
            ALPN = {alpn_advertised_protocols, [<<"h2">>]},
            [ALPN | SockOpts ++ SSLOpts];
        gen_tcp ->
            ClientOpts
    end.


accept_preface(Socket) ->
    case sock:recv(Socket, size(?PREFACE), 5000) of
        {ok, ?PREFACE} ->
            ok;
        _E ->
            sock:close(Socket),
            {error, invalid_preface}
    end.


handle_socket_data(<<>>, Conn) ->
    #connection{
        socket = Socket
    } = Conn,
    active_once(Socket),
    {keep_state, Conn};

handle_socket_data(Data, Conn) ->
    #connection{
        buffer = Buffer
    } = Conn

    ToParse = case Buffer of
        empty ->
            Data;
        {binary, Bin} ->
            <<Bin/binary, Data/binary>>
        {frame, Frame, Bin} ->
            {Frame, <<Bin/binary, Data/binary>>};
    end,

    NewConn = Conn#connection{buffer = empty},

    {Buffer, Events} = case h2_frame:recv(ToParse) of
        %% We got a full frame, ship it off to the FSM
        {ok, Frame, Rest} ->
            {{binary, Rest}, [{next_event, internal, {frame, Frame}}]};
        {not_enough_header, Bin} ->
            %% This is a situation where more bytes should come soon,
            %% so let's switch back to active, once
            active_once(Socket),
            {keep_state, NewConn#connection{buffer={binary, Bin}}};
        %% Not enough bytes to make a payload
        {not_enough_payload, Header, Bin} ->
            %% This too
            active_once(Socket),
            {keep_state, NewConn#connection{buffer={frame, Header, Bin}}};
        {error, 0, Code, _Rem} ->
            %% Remaining Bytes don't matter, we're closing up shop.
            go_away(Code, NewConn);
        {error, StreamId, Code, Rem} ->
            Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
            rst_stream(Stream, Code, NewConn),
            handle_socket_data(Rem, NewConn)
    end.


handle_socket_passive(Conn) ->
    {keep_state, Conn}.


handle_socket_closed(Conn) ->
    {stop, normal, Conn}.


handle_socket_error(Reason, Conn) ->
    {stop, Reason, Conn}.


socksend(#connection{
            socket=Socket
           }, Data) ->
    case sock:send(Socket, Data) of
        ok ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.


-spec handle_continuation(continuation(), connection()) ->
        {next_state, atom(), connection()}.
handle_continuation(#{end_headers := true} = Cont, Conn)
    #{
        stream_id := StreamId,
        type := Type,
        frames := Frames,
        end_stream := EndStream
    } = Cont,
    #connection{
        decode_context = DecCtx,
        streams = Streams1
    } = Conn,
    HeadersBin = h2_headers:from_frames(queue:to_list(Frames)),
    case hpack:decode(HeadersBin, DecCtx) of
        {ok, {Headers, NewDecCtx}} ->
            Streams2 = case Type of
                headers ->
                    h2_stream_set:handle_headers(
                            Streams1,
                            StreamId,
                            Headers,
                            EndStream
                        );
                push_promise ->
                    h2_stream_set:handle_push_promise(
                            Streams1,
                            StreamId,
                            maps:get(promised_id, Cont),
                            Headers
                        )
            end,
            NewConn = Conn#connection{
                decode_context = NewDecCtx,
                streams = Streams2,
                continuation = undefined
            },
            {next_state, connected, NewConn};
        {error, compression_error} ->
            go_away(?COMPRESSION_ERROR, Conn);
    end;
handle_continuation(Cont, Conn) ->
    NewConn = Conn#connection{
        continuation = Cont
    },
    {next_state, continuation, NewConn}.

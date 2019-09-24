-module(h2_connection).
-include("http2.hrl").
-behaviour(gen_statem).

%% Start/Stop API
-export([
         start_client_link/5,
         become/3,
         stop/1
        ]).

%% HTTP Operations
-export([
         send_headers/3,
         send_headers/4,
         send_trailers/3,
         send_trailers/4,
         send_body/3,
         send_body/4,
         send_request/3,
         send_ping/1,
         is_push/1,
         new_stream/1,
         new_stream/2,
         send_promise/4,
         get_response/2,
         get_peer/1,
         get_peercert/1,
         get_streams/1,
         send_window_update/2,
         update_settings/2,
         send_frame/2
        ]).

%% gen_statem callbacks
-export(
   [
    init/1,
    callback_mode/0,
    code_change/4,
    terminate/3
   ]).

%% gen_statem states
-export([
         handshake/3,
         connected/3,
         continuation/3,
         closing/3
        ]).

-export([
         go_away/2
        ]).

-record(continuation_state, {
          stream_id                 :: stream_id(),
          promised_id = undefined   :: undefined | stream_id(),
          frames      = queue:new() :: queue:queue(h2_frame:frame()),
          type                      :: headers | push_promise | trailers,
          end_stream  = false       :: boolean(),
          end_headers = false       :: boolean()
}).

-record(connection, {
          type = undefined :: client | server | undefined,
          socket = undefined :: sock:socket(),
          peer_settings = #settings{} :: settings(),
          self_settings = #settings{} :: settings(),
          send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
          decode_context = hpack:new_context() :: hpack:context(),
          encode_context = hpack:new_context() :: hpack:context(),
          settings_sent = queue:new() :: queue:queue(),
          next_available_stream_id = 2 :: stream_id(),
          streams :: h2_stream_set:stream_set(),
          stream_callback_mod :: undefined | module(),
          stream_callback_opts = [] :: list(),
          buffer = empty :: empty | {binary, binary()} | {frame, h2_frame:header(), binary()},
          continuation = undefined :: undefined | #continuation_state{},
          flow_control = auto :: auto | manual,
          pings = #{} :: #{binary() => {pid(), non_neg_integer()}}
}).

-type connection() :: #connection{}.

-type send_option() :: {send_end_stream, boolean()}.
-type send_opts() :: [send_option()].

-export_type([send_option/0, send_opts/0]).


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
    CBMod = maps:get(stream_callback_mod, ConnectionSettings, undefined),
    CBOpts = maps:get(stream_callback_opts, ConnectionSettings, undefined),

    Conn = #connection{
        stream_callback_mod = CBMod,
        stream_callback_opts = CBOpts,
        streams = h2_stream_set:new(server),
        socket = {Transport, Socket}
    }
    case init_server(Http2Settings, Opts) of
        {_, handshake, NewState} ->
            gen_statem:enter_loop(?MODULE, [], handshake, NewState);
        {_, closing, _NewState} ->
            sock:close({Transport, Socket}),
            exit(invalid_preface)
    end.

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
        streams = h2_stream_set:new(client),
        socket = {Transport, Socket},
        next_available_stream_id = 1,
        flow_control = auto
    },
    {ok, handshake, send_settings(Http2Settings, InitialState), 4500}.

callback_mode() ->
    state_functions.

send_frame(Pid, Bin)
  when is_binary(Bin); is_list(Bin) ->
    gen_statem:cast(Pid, {send_bin, Bin});
send_frame(Pid, Frame) ->
    gen_statem:cast(Pid, {send_frame, Frame}).

-spec send_headers(pid(), stream_id(), hpack:headers()) -> ok.
send_headers(Pid, StreamId, Headers) ->
    gen_statem:cast(Pid, {send_headers, StreamId, Headers, []}),
    ok.

-spec send_headers(pid(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_headers(Pid, StreamId, Headers, Opts) ->
    gen_statem:cast(Pid, {send_headers, StreamId, Headers, Opts}),
    ok.

-spec send_trailers(pid(), stream_id(), hpack:headers()) -> ok.
send_trailers(Pid, StreamId, Trailers) ->
    gen_statem:cast(Pid, {send_trailers, StreamId, Trailers, []}),
    ok.

-spec send_trailers(pid(), stream_id(), hpack:headers(), send_opts()) -> ok.
send_trailers(Pid, StreamId, Trailers, Opts) ->
    gen_statem:cast(Pid, {send_trailers, StreamId, Trailers, Opts}),
    ok.

-spec send_body(pid(), stream_id(), binary()) -> ok.
send_body(Pid, StreamId, Body) ->
    gen_statem:cast(Pid, {send_body, StreamId, Body, []}),
    ok.
-spec send_body(pid(), stream_id(), binary(), send_opts()) -> ok.
send_body(Pid, StreamId, Body, Opts) ->
    gen_statem:cast(Pid, {send_body, StreamId, Body, Opts}),
    ok.

-spec send_request(pid(), hpack:headers(), binary()) -> ok.
send_request(Pid, Headers, Body) ->
    gen_statem:call(Pid, {send_request, self(), Headers, Body}, infinity),
    ok.

-spec send_ping(pid()) -> ok.
send_ping(Pid) ->
    gen_statem:call(Pid, {send_ping, self()}, infinity),
    ok.

-spec get_peer(pid()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
get_peer(Pid) ->
    gen_statem:call(Pid, get_peer).

-spec get_peercert(pid()) ->
    {ok, binary()} | {error, term()}.
get_peercert(Pid) ->
    gen_statem:call(Pid, get_peercert).

-spec is_push(pid()) -> boolean().
is_push(Pid) ->
    gen_statem:call(Pid, is_push).

-spec new_stream(pid()) -> stream_id() | {error, error_code()}.
new_stream(Pid) ->
    new_stream(Pid, self()).

-spec new_stream(pid(), pid()) ->
                        stream_id()
                      | {error, error_code()}.
new_stream(Pid, NotifyPid) ->
    gen_statem:call(Pid, {new_stream, NotifyPid}).

-spec send_promise(pid(), stream_id(), stream_id(), hpack:headers()) -> ok.
send_promise(Pid, StreamId, NewStreamId, Headers) ->
    gen_statem:cast(Pid, {send_promise, StreamId, NewStreamId, Headers}),
    ok.

-spec get_response(pid(), stream_id()) ->
                          {ok, {hpack:headers(), iodata()}}
                           | not_ready.
get_response(Pid, StreamId) ->
    gen_statem:call(Pid, {get_response, StreamId}).

-spec get_streams(pid()) -> h2_stream_set:stream_set().
get_streams(Pid) ->
    gen_statem:call(Pid, streams).

-spec send_window_update(pid(), non_neg_integer()) -> ok.
send_window_update(Pid, Size) ->
    gen_statem:cast(Pid, {send_window_update, Size}).

-spec update_settings(pid(), h2_frame_settings:payload()) -> ok.
update_settings(Pid, Payload) ->
    gen_statem:cast(Pid, {update_settings, Payload}).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_statem:cast(Pid, stop).

-spec handshake(gen_statem:event_type(), {frame, h2_frame:frame()} | term(), connection()) ->
                    {next_state,
                     handshake|connected|closing,
                     connection()}.
handshake(timeout, _, Conn) ->
    go_away(?PROTOCOL_ERROR, Conn);
handshake(_, {frame, #frame{type = ?SETTINGS}}, Conn) ->
    %% The first frame should be the client settings as per
    %% RFC-7540#3.5
    route_frame(Frame, Conn);
handshake(_, {frame, _Frame}, Conn) ->
    go_away(?PROTOCOL_ERROR, Conn);
handshake(Type, Msg, Conn) ->
    handle_event(Type, Msg, Conn).

connected(_, {frame, Frame}, #connection{}=Conn) ->
    route_frame(Frame, Conn);
connected(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% The continuation state in entered after receiving a HEADERS frame
%% with no ?END_HEADERS flag set, we're locked waiting for contiunation
%% frames on the same stream to preserve the decoding context state
continuation(_, {frame, #frame{type = Type} = Frame}, #connetion{} = Conn)
        when Type == ?CONTINUATION ->
    #frame{
        stream_id = StreamId
    } = Frame,
    #connection{
        continuation = #continuation_state{
            stream_id = ContStreamId
        }
    } = Conn,
    case ContStreamId == StreamId of
        true ->
            route_frame(Frame, Conn);
        false ->
            go_away(?PROTOCOL_ERROR, Conn)
    end;
continuation(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% The closing state should deal with frames on the wire still, I
%% think. But we should just close it up now.
closing(_, _Message, #connection{} = Conn) ->
    #connection{
        socket = Socket
    } = Conn,
    sock:close(Socket),
    {stop, normal, Conn};
closing(Type, Msg, State) ->
    handle_event(Type, Msg, State).

%% route_frame's job needs to be "now that we've read a frame off the
%% wire, do connection based things to it and/or forward it to the
%% http2 stream processor (h2_stream:recv_frame)
-spec route_frame(h2:frame() | {error, term()}, connection()) ->
    {next_state, connected | continuation | closing, connection()}.

%% Bad Length of frame, exceedes maximum allowed size
route_frame(
            #frame{length = Length},
            #connection{self_settings = #settings{max_frame_size = MFS}} = Conn
        ) when Length > MFS ->
    go_away(?FRAME_SIZE_ERROR, Conn);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Connection Level Frames
%%
%% Here we'll handle anything that belongs on stream 0.

%% SETTINGS, finally something that's ok on stream 0
%% This is the non-ACK case, where settings have actually arrived
route_frame(#frame{type = Type, flags = Flags} = Frame, #connection{} = Conn)
        when Type == ?SETTINGS, ?NOT_FLAG(Flags, ?ACK) ->
    #frame{
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

    %% Need a way of processing settings so I know which ones came in
    %% on this one payload.
    case h2_settings:validate(Settings) of
        ok ->
            NewSettings = h2_settings:merge(OldSettings, Settings),

            TableSize = NewSettings#settings.header_table_size,

            NewEncCtx = hpack:new_max_table_size(TableSize, EncCtx),

            Delta = NewSettings#settings.initial_window_size -
                    OldSettings#settings.initial_window_size,

            MaxActive = NewSettings#settings.max_concurrent_streams,

            Streams2 = h2_stream_set:update_all_send_windows(Delta, Streams1),
            Streams3 = h2_stream_set:update_my_max_active(MaxActive, Streams2),

            send_frames(Conn, h2_frame:settings_ack()),

            %% Why aren't we updating send_window_size here? Section 6.9.2 of
            %% the spec says: "The connection flow-control window can only be
            %% changed using WINDOW_UPDATE frames.",
            NewConn = Conn#connection{
                peer_settings = NewSettings,
                encode_context = NewEncCtx,
                streams = Streams3
            },

            {next_state, connected, NewConn};
        {error, Code} ->
            go_away(Code, Conn)
    end;

%% This is the case where we got an ACK, so dequeue settings we're
%% waiting to apply
route_frame(#frame{type = Type, flags = Flags} = Frame, #connection{} = Conn)
        when Type == ?SETTINGS, ?IS_FLAG(Flags, ?ACK) ->
    #connection{
        settings_sent = SettingsSent,
        streams = Streams,
        self_settings = #settings{
            initial_window_size = OldWindowSize
        }
    } = Conn,

    case queue:out(SettingsSent) of
        {{value, {_Ref, NewSettings}}, NewSettingsSent} ->
            Delta = NewSettings#settings.initial_window_size - OldWindowSize,
            NewMax = NewSettings#settings.max_concurrent_streams,

            Streams2 = case Delta of
                0 -> Streams1;
                _ -> h2_stream_sent:update_all_recv_windows(Delta, Streams1)
            end,

            Streams3 = h2_stream_set:update_their_max_active(NewMax, Streams2),

            NewConn = Conn#connection{
                settings_sent = NewSettingsSent,
                self_settings = NewSettings
                streams = Streams3
            },

            {next_state, connected, NewConn};
        _X ->
            {next_state, closing, Conn}
    end;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Stream level frames
%%

%% receive data frame bigger than connection recv window
route_frame(#frame{type = ?DATA, length = Length}, Conn)
        when Length > Conn#connection.recv_window_size ->
    go_away(?FLOW_CONTROL_ERROR, Conn);

route_frame(#frame{type = ?DATA} = Frame, #connection{} = Conn) ->
    #frame{
        length = Length,
        stream_id = StreamId
    } = Frame,
    #connection{
        recv_window_size = CurrWindowSize,
        streams = Streams1
    } = Conn,

    Stream = h2_stream_set:get(StreamId, Streams),

    case h2_stream_set:type(Stream) of
        active ->
            ExceededWindow = h2_stream_set:recv_window_size(Stream) < Length,

            case {ExceededWindow, Conn#connection.flow_control, Length > 0} of
                {true, _, _} ->
                    rst_stream(Stream, ?FLOW_CONTROL_ERROR, Conn);
                %% If flow control is set to auto, and L > 0, send
                %% window updates back to the peer. If L == 0, we're
                %% not allowed to send window_updates of size 0, so we
                %% hit the next clause
                {false, auto, true} ->
                    ToSend = [
                        h2_frame:window_update(0, Length),
                        h2_frame:window_update(StreamId, Length)
                    ],
                    send_frames(Conn, ToSend),
                    recv_data(Stream, Frame),
                    {next_state, connected, Conn};
                %% Either
                %% {false, auto, true} or
                %% {false, manual, _DoesntMatter}
                _Tried ->
                    recv_data(Stream, F),
                    NewS = h2_stream_set:decrement_recv_window(Length, Stream),
                    NewConn = Conn#connection{
                        recv_window_size = CurrWindowSize - Length,
                        streams = h2_stream_set:upsert(NewS, Streams1)
                    }
                    {next_state, connected, NewConn}
            end;
        _ ->
            go_away(?PROTOCOL_ERROR, Conn)
    end;

route_frame({#frame{type = ?HEADERS, stream_id = StreamId}, Conn)
        when Conn#connection.type == server, StreamId rem 2 == 0 ->
    go_away(?PROTOCOL_ERROR, Conn);
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
    {ContinuationType, NewConn} = case {ConnType, StreamType} of
        {server, idle} ->
            case create_stream(Conn, StreamId, self()) of
                {ok, NewStreams} ->
                    {headers, Conn#connetion{streams = NewStreams}};
                {error, ErrorCode, NewStream} ->
                    rst_stream(NewStream, ErrorCode, Conn),
                    {none, Conn}
            end;
        {server, active} ->
            {trailers, Conn};
        {server, closed} ->
            {{error, ?PROTOCOL_ERROR}, Conn};
        {client, idle} ->
            {{error, ?PROTOCOL_ERROR}, Conn};
        {client, active} ->
            {headers, Conn};
        {client, closed} ->
            {{error, ?PROTOCOL_ERROR}, Conn}
    end,

    case ContinuationType of
        {error, Code} ->
            go_away(Code, NewConn);
        none ->
            {next_state, connected, NewConn};
        _ ->
            ContState = #continuation_state{
                type = ContinuationType,
                stream_id = StreamId,
                frames = queue:from_list([Frame]),
                end_stream = ?IS_FLAG(Flags, ?END_STREAM),
                end_headers = ?IS_FLAG(Flags, ?END_HEADERS)
            },
            maybe_hpack(ContState, NewConn)
    end;

route_frame(#frame{type = ?CONTINUATION} = Frame, Conn) ->
    #frames{
        flags = Flags
    } = Frame,
    #connection{
        continuation = #continuation_state{
            frames = CFQ
        } = Cont
    } = Conn,
    NewCont = Cont#continuation_state{
        frames=queue:in(F, CFQ),
        end_headers=?IS_FLAG(Flags, ?END_HEADERS)
    },
    maybe_hpack(NewCont, Conn);

route_frame(#frame{type = ?PRIORITY, stream_id = 0}, Conn) ->
    go_away(?PROTOCOL_ERROR, Conn);
route_frame(#frame{type = ?PRIORITY} = Frame, Conn) ->
    {next_state, connected, Conn};

route_frame(#frame{type = ?RST_STREAM} = Frame, Conn) ->
    #frame{
        data = ErrorCode
    } = Frame,
    #connection{
        streams = Streams1
    } = Conn,
    Stream = h2_stream_set:get(StreamId, Streams1),
    case h2_stream_set:type(Stream) of
        idle ->
            go_away(?PROTOCOL_ERROR, Conn);
        active ->
            Streams2 = h2_stream_set:reset(Stream, ErrorCode, Streams1),
            NewConn = Conn#connection{
                streams = Streams2
            },
            {next_state, connected, NewConn}
    end;

route_frame(#frame{type = ?PUSH_PROMISE}, Conn) ->
        when Conn#connection.type == server ->
    go_away(?PROTOCOL_ERROR, Conn);
route_frame(#frame{type = ?PUSH_PROMISE} = Frame, Conn) ->
        when Conn#connection.type == client ->
    #frame{
        stream_id = StreamId,
        data = {PromisedStreamId, _, _}
    } = Frame,

    Streams = Conn#connection.streams,

    Continuation = #continuation_state{
        stream_id = StreamId,
        type = push_promise,
        frames = queue:in(Frame, queue:new()),
        end_headers = ?IS_FLAG(Flags, ?END_HEADERS),
        promised_id = PromisedStreamId
    },
    NewConn = Conn#connection{
        streams = NewStreams
    },
    maybe_hpack(Continuation, NewConn);

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
    }
    go_away(ErrorCode, Conn);

route_frame(#frame{type = ?WINDOW_UPDATE, stream_id = 0}, Conn) ->
    #frame{
        data = Increment
    } = Frame,
    #connection{
        send_window_size = SendWindowSize,
        peer_settings = #settings{
            max_frame_size = MaxFrameSize
        },
        streams = Streams1
    } = Conn
    NewSendWindow = SendWindowSize + Increment,
    case NewSendWindow > 2147483647 of
        true ->
            go_away(?FLOW_CONTROL_ERROR, Conn);
        false ->
            %% TODO: Priority Sort! Right now, it's just sorting on
            %% lowest stream_id first
            Streams2 = h2_stream_set:sort(Streams1)
            {RemainingSendWindow, Streams3} = h2_stream_set:send_what_we_can(
                    all,
                    NewSendWindow,
                    MaxFrameSize,
                    Streams2
                 ),
            NewConn = Conn#connection{
                send_window_size = RemainingSendWindow,
                streams = Streams3
            },
            {next_state, connected, NewConn};
    end;
route_frame(#frame{type = ?WINDOW_UPDATE}, Conn) ->
    #frame{
        stream_id = StreamId,
        data = Increment
    } = Frame,
    #connection{
        send_window_size = SendWindowSize,
        streams = Streams1,
        peer_settings = #settings{
            max_frame_size = MaxFrameSize
        }
    } = Conn,

    Stream = h2_stream_set:get(StreamId, Streams1),

    case h2_stream_set:type(Stream) of
        idle ->
            go_away(?PROTOCOL_ERROR, Conn);
        closed ->
            rst_stream(Stream, ?STREAM_CLOSED, Conn);
        active ->
            StreamWindowSize = h2_stream_set:send_window_size(Stream),
            NewStreamWindowSize = StreamWindowSize + Increment,

            case NewStreamWindowSize > 2147483647 of
                true ->
                    rst_stream(Stream, ?FLOW_CONTROL_ERROR, Conn);
                false ->
                    NewStream = h2_stream_set:increment_send_window_size(
                            Increment,
                            Stream
                        ),
                    Streams2 = h2_stream_set:upsert(NewStream, Streams1),
                    {RemainingSendWindow, Streams3}
                        = h2_stream_set:send_what_we_can(
                                StreamId,
                                SendWindowSize,
                                MaxFrameSize,
                                Streams2
                            ),
                    NewConn = Conn#connection{
                        send_window_size = RemainingSendWindow,
                        streams = Streams3
                    },
                    {next_state, connected, NewConn}
            end
    end;

route_frame(#frame{type = Type}, Conn) when Type > ?CONTINUATION ->
    {next_state, connected, Conn};

route_frame(Frame, Conn) ->
    Msg = "Frame condition not covered by pattern match."
            "Please open a github issue with this output: ~s",
    error_logger:error_msg(Msg, [h2_frame:format(Frame)]),
    go_away(?PROTOCOL_ERROR, Conn).


handle_event(_, {stream_finished, StreamId, Headers, Body}, Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            NotifyPid = h2_stream_set:notify_pid(Stream),
            Response =
                case Conn#connection.type of
                    server -> garbage;
                    client -> {Headers, Body}
                end,
            {_NewStream, NewStreams} = h2_stream_set:close(
                    Stream,
                    Response,
                    Conn#connection.streams
                ),

            NewConn = Conn#connection{
                streams = NewStreams
            },
            case {Conn#connection.type, is_pid(NotifyPid)} of
                {client, true} ->
                    NotifyPid ! {'END_STREAM', StreamId};
                _ ->
                    ok
            end,
            {keep_state, NewConn};
        _ ->
            %% stream finished multiple times
            {keep_state, Conn}
    end;

handle_event(_, {update_settings, Http2Settings}, Conn) ->
    {keep_state, send_settings(Http2Settings, Conn)};

handle_event(_, {send_headers, StreamId, Headers, Opts}, Conn) ->
    #connection{
        encode_context=EncodeCtx,
        streams = Streams,
        socket = Socket,
        peer_settings = #settings{
            max_frame_size = MaxFrameSize
        }
    } = Conn,

    StreamComplete = proplists:get_value(send_end_stream, Opts, false),
    Stream = h2_stream_set:get(StreamId, Streams),

    case h2_stream_set:type(Stream) of
        active ->
            {Frames, NewCtx} = h2_headers:to_frames(
                    StreamId,
                    Headers,
                    EncodeCtx,
                    MaxFrameSize,
                    StreamComplete
                ),

            send_frames(Conn, Frames),

            NewConn = Conn#connection{
                encode_context = NewContext
            },
            {keep_state, NewConn};
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            {keep_state, Conn};
        closed ->
            {keep_state, Conn}
    end;

handle_event(_, {send_trailers, StreamId, Headers, _Opts}, Conn) ->
    #connection{
        encode_context = EncodeCtx,
        streams = Streams,
        peer_settings = #settings{
            max_frame_size = MaxFrameSize
        }
    } = Conn,
    Stream = h2_stream_set:get(StreamId, Streams),
    case h2_stream_set:type(Stream) of
        active ->
            {FramesToSend, NewContext} =
                h2_headers:to_frames(
                        StreamId,
                        Headers,
                        EncodeCtx,
                        MaxFrameSize,
                        true
                    ),
            NewStream = h2_stream_set:update_trailers(FramesToSend, Stream),

            {NewSWS, NewStreams} =
                h2_stream_set:send_what_we_can(
                  StreamId,
                  Conn#connection.send_window_size,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
                  h2_stream_set:upsert(
                    h2_stream_set:update_data_queue(h2_stream_set:queued_data(Stream), false, NewS),
                    Conn#connection.streams)),

            send_t(Stream, Headers),
            {keep_state,
             Conn#connection{
               encode_context=NewContext,
               send_window_size=NewSWS,
               streams=NewStreams
              }};
        idle ->
            %% In theory this is a client maybe activating a stream,
            %% but in practice, we've already activated the stream in
            %% new_stream/1
            {keep_state, Conn};
        closed ->
            {keep_state, Conn}
    end;
handle_event(_, {send_body, StreamId, Body, Opts},
             #connection{}=Conn) ->
    BodyComplete = proplists:get_value(send_end_stream, Opts, true),

    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    case h2_stream_set:type(Stream) of
        active ->
            OldBody = h2_stream_set:queued_data(Stream),
            NewBody = case is_binary(OldBody) of
                          true -> <<OldBody/binary, Body/binary>>;
                          false -> Body
                      end,
            {NewSWS, NewStreams} =
                h2_stream_set:send_what_we_can(
                  StreamId,
                  Conn#connection.send_window_size,
                  (Conn#connection.peer_settings)#settings.max_frame_size,
                  h2_stream_set:upsert(
                    h2_stream_set:update_data_queue(NewBody, BodyComplete, Stream),
                    Conn#connection.streams)),

            {keep_state,
             Conn#connection{
               send_window_size=NewSWS,
               streams=NewStreams
              }};
        idle ->
            %% Sending DATA frames on an idle stream?  It's a
            %% Connection level protocol error on reciept, but If we
            %% have no active stream what can we even do?
            {keep_state, Conn};
        closed ->
            {keep_state, Conn}
    end;

handle_event(_, {send_request, NotifyPid, Headers, Body},
        #connection{
            streams=Streams,
            next_available_stream_id=NextId
        }=Conn) ->
    case send_request(NextId, NotifyPid, Conn, Streams, Headers, Body) of
        {ok, GoodStreamSet} ->
            {keep_state, Conn#connection{
                next_available_stream_id=NextId+2,
                streams=GoodStreamSet
            }};
        {error, _Code} ->
            {keep_state, Conn}
    end;

handle_event(_, {send_promise, StreamId, NewStreamId, Headers},
             #connection{
                streams=Streams,
                encode_context=OldContext
               }=Conn
            ) ->
    NewStream = h2_stream_set:get(NewStreamId, Streams),
    case h2_stream_set:type(NewStream) of
        active ->
            %% TODO: This could be a series of frames, not just one
            {PromiseFrame, NewContext} =
                h2_frame_push_promise:to_frame(
               StreamId,
               NewStreamId,
               Headers,
               OldContext
              ),

            %% Send the PP Frame
            Binary = h2_frame:to_binary(PromiseFrame),
            socksend(Conn, Binary),

            %% Get the promised stream rolling
            h2_stream:send_pp(h2_stream_set:stream_pid(NewStream), Headers),

            {keep_state,
             Conn#connection{
               encode_context=NewContext
              }};
        _ ->
            {keep_state, Conn}
    end;

handle_event(_, {check_settings_ack, {Ref, NewSettings}},
             #connection{
                settings_sent=SS
               }=Conn) ->
    case queue:out(SS) of
        {{value, {Ref, NewSettings}}, _} ->
            %% This is still here!
            go_away(?SETTINGS_TIMEOUT, Conn);
        _ ->
            %% YAY!
            {keep_state, Conn}
    end;
handle_event(_, {send_bin, Binary},
             #connection{} = Conn) ->
    socksend(Conn, Binary),
    {keep_state, Conn};
handle_event(_, {send_frame, Frame},
             #connection{} =Conn) ->
    Binary = h2_frame:to_binary(Frame),
    socksend(Conn, Binary),
    {keep_state, Conn};
handle_event(stop, _StateName,
            #connection{}=Conn) ->
    go_away(0, Conn);
handle_event({call, From}, streams,
                  #connection{
                     streams=Streams
                    }=Conn) ->
    {keep_state, Conn, [{reply, From, Streams}]};
handle_event({call, From}, {get_response, StreamId},
                  #connection{}=Conn) ->
    Stream = h2_stream_set:get(StreamId, Conn#connection.streams),
    {Reply, NewStreams} =
        case h2_stream_set:type(Stream) of
            closed ->
                {_, NewStreams0} =
                    h2_stream_set:close(
                      Stream,
                      garbage,
                      Conn#connection.streams),
                {{ok, h2_stream_set:response(Stream)}, NewStreams0};
            active ->
                {not_ready, Conn#connection.streams}
        end,
    {keep_state, Conn#connection{streams=NewStreams}, [{reply, From, Reply}]};
handle_event({call, From}, {new_stream, NotifyPid},
                  #connection{
                     streams=Streams,
                     next_available_stream_id=NextId
                    }=Conn) ->
    {Reply, NewStreams} =
        case
            h2_stream_set:new_stream(
              NextId,
              NotifyPid,
              Conn#connection.stream_callback_mod,
              Conn#connection.stream_callback_opts,
              Conn#connection.socket,
              Conn#connection.peer_settings#settings.initial_window_size,
              Conn#connection.self_settings#settings.initial_window_size,
              Streams)
        of
            {error, Code, _NewStream} ->
                %% TODO: probably want to have events like this available for metrics
                %% tried to create new_stream but there are too many
                {{error, Code}, Streams};
            GoodStreamSet ->
                {NextId, GoodStreamSet}
        end,
    {keep_state, Conn#connection{
                                 next_available_stream_id=NextId+2,
                                 streams=NewStreams
                                }, [{reply, From, Reply}]};
handle_event({call, From}, is_push,
                  #connection{
                     peer_settings=#settings{enable_push=Push}
                    }=Conn) ->
    IsPush = case Push of
        1 -> true;
        _ -> false
    end,
    {keep_state, Conn, [{reply, From, IsPush}]};
handle_event({call, From}, get_peer,
                  #connection{
                     socket=Socket
                    }=Conn) ->
    case sock:peername(Socket) of
        {error, _}=Error ->
            {keep_state, Conn, [{reply, From, Error}]};
        {ok, _AddrPort}=OK ->
            {keep_state, Conn, [{reply, From, OK}]}
    end;
handle_event({call, From}, get_peercert,
                  #connection{
                     socket=Socket
                    }=Conn) ->
    case sock:peercert(Socket) of
        {error, _}=Error ->
            {keep_state, Conn, [{reply, From, Error}]};
        {ok, _Cert}=OK ->
            {keep_state, Conn, [{reply, From, OK}]}
    end;
handle_event({call, From}, {send_request, NotifyPid, Headers, Body},
        #connection{
            streams=Streams,
            next_available_stream_id=NextId
        }=Conn) ->
    case send_request(NextId, NotifyPid, Conn, Streams, Headers, Body) of
        {ok, GoodStreamSet} ->
            {keep_state, Conn#connection{
                next_available_stream_id=NextId+2,
                streams=GoodStreamSet
            }, [{reply, From, ok}]};
        {error, Code} ->
            {keep_state, Conn, [{reply, From, {error, Code}}]}
    end;
handle_event({call, From}, {send_ping, NotifyPid},
             #connection{pings = Pings} = Conn) ->
    PingValue = crypto:strong_rand_bytes(8),
    Frame = h2_frame_ping:new(PingValue),
    Headers = #frame_header{stream_id = 0, flags = 16#0},
    Binary = h2_frame:to_binary({Headers, Frame}),

    case socksend(Conn, Binary) of
        ok ->
            NextPings = maps:put(PingValue, {NotifyPid, erlang:monotonic_time(milli_seconds)}, Pings),
            NextConn = Conn#connection{pings = NextPings},
            {keep_state, NextConn, [{reply, From, ok}]};
        {error, _Reason} = Err ->
            {keep_state, Conn, [{reply, From, Err}]}
    end;

%% Socket Messages
%% {tcp, Socket, Data}
handle_event(info, {tcp, Socket, Data},
            #connection{
               socket={gen_tcp,Socket}
              }=Conn) ->
    handle_socket_data(Data, Conn);
%% {ssl, Socket, Data}
handle_event(info, {ssl, Socket, Data},
            #connection{
               socket={ssl,Socket}
              }=Conn) ->
    handle_socket_data(Data, Conn);
%% {tcp_passive, Socket}
handle_event(info, {tcp_passive, Socket},
            #connection{
               socket={gen_tcp, Socket}
              }=Conn) ->
    handle_socket_passive(Conn);
%% {tcp_closed, Socket}
handle_event(info, {tcp_closed, Socket},
            #connection{
              socket={gen_tcp, Socket}
             }=Conn) ->
    handle_socket_closed(Conn);
%% {ssl_closed, Socket}
handle_event(info, {ssl_closed, Socket},
            #connection{
               socket={ssl, Socket}
              }=Conn) ->
    handle_socket_closed(Conn);
%% {tcp_error, Socket, Reason}
handle_event(info, {tcp_error, Socket, Reason},
            #connection{
               socket={gen_tcp,Socket}
              }=Conn) ->
    handle_socket_error(Reason, Conn);
%% {ssl_error, Socket, Reason}
handle_event(info, {ssl_error, Socket, Reason},
            #connection{
               socket={ssl,Socket}
              }=Conn) ->
    handle_socket_error(Reason, Conn);
handle_event(info, {_,R},
           #connection{}=Conn) ->
    handle_socket_error(R, Conn);
handle_event(_, _, Conn) ->
     go_away(?PROTOCOL_ERROR, Conn).

code_change(_OldVsn, StateName, Conn, _Extra) ->
    {ok, StateName, Conn}.

terminate(normal, _StateName, _Conn) ->
    ok;
terminate(_Reason, _StateName, _Conn=#connection{}) ->
    ok;
terminate(_Reason, _StateName, _State) ->
    ok.

-spec go_away(error_code(), connection()) -> {next_state, closing, connection()}.
go_away(ErrorCode,
        #connection{
           next_available_stream_id=NAS
          }=Conn) ->
    GoAway = h2_frame_goaway:new(NAS, ErrorCode),
    GoAwayBin = h2_frame:to_binary({#frame_header{
                                       stream_id=0
                                      }, GoAway}),
    socksend(Conn, GoAwayBin),
    %% TODO: why is this sending a string?
    gen_statem:cast(self(), io_lib:format("GO_AWAY: ErrorCode ~p", [ErrorCode])),
    {next_state, closing, Conn}.

%% rst_stream/3 looks for a running process for the stream. If it
%% finds one, it delegates sending the rst_stream frame to it, but if
%% it doesn't, it seems like a waste to spawn one just to kill it
%% after sending that frame, so we send it from here.
-spec rst_stream(
        h2_stream_set:stream(),
        error_code(),
        connection()
       ) ->
                        {next_state, connected, connection()}.
rst_stream(Stream, ErrorCode, Conn) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% Can this ever be undefined?
            Pid = h2_stream_set:stream_pid(Stream),
            %% h2_stream's rst_stream will take care of letting us know
            %% this stream is closed and will send us a message to close the
            %% stream somewhere else
            h2_stream:rst_stream(Pid, ErrorCode),
            {next_state, connected, Conn};
        _ ->
            StreamId = h2_stream_set:stream_id(Stream),
            RstStream = h2_frame_rst_stream:new(ErrorCode),
            RstStreamBin = h2_frame:to_binary(
                          {#frame_header{
                              stream_id=StreamId
                             },
                           RstStream}),
            sock:send(Conn#connection.socket, RstStreamBin),
            {next_state, connected, Conn}
    end.

-spec send_settings(settings(), connection()) -> connection().
send_settings(SettingsToSend,
              #connection{
                 self_settings=CurrentSettings,
                 settings_sent=SS
                }=Conn) ->
    Ref = make_ref(),
    Bin = h2_frame_settings:send(CurrentSettings, SettingsToSend),
    socksend(Conn, Bin),
    send_ack_timeout({Ref,SettingsToSend}),
    Conn#connection{
      settings_sent=queue:in({Ref, SettingsToSend}, SS)
     }.

-spec send_ack_timeout({reference(), settings()}) -> pid().
send_ack_timeout(SS) ->
    Self = self(),
    SendAck = fun() ->
                  timer:sleep(5000),
                  gen_statem:cast(Self, {check_settings_ack,SS})
              end,
    spawn_link(SendAck).

%% private socket handling
active_once(Socket) ->
    sock:setopts(Socket, [{active, once}]).

client_options(Transport, SSLOptions) ->
    ClientSocketOptions = [
                           binary,
                           {packet, raw},
                           {active, false}
                          ],
    case Transport of
        ssl ->
            [{alpn_advertised_protocols, [<<"h2">>]}|ClientSocketOptions ++ SSLOptions];
        gen_tcp ->
            ClientSocketOptions
    end.

init_server(Http2Settings, Conn) ->
    #connection{
        socket = Socket
    } = Conn,
    case accept_preface(Socket) of
        ok ->
            ok = active_once(Socket),
            NewState = Conn#connection{
                type = server,
                next_available_stream_id = 2,
                flow_control = auto
            },
            {next_state, handshake, send_settings(Http2Settings, NewState)};
        {error, invalid_preface} ->
            {next_state, closing, Conn}
    end.

%% We're going to iterate through the preface string until we're done
%% or hit a mismatch
accept_preface(Socket) ->
    accept_preface(Socket, <<?PREFACE>>).

accept_preface(_Socket, <<>>) ->
    ok;
accept_preface(Socket, <<Char:8,Rem/binary>>) ->
    case sock:recv(Socket, 1, 5000) of
        {ok, <<Char>>} ->
            accept_preface(Socket, Rem);
        _E ->
            sock:close(Socket),
            {error, invalid_preface}
    end.

%% Incoming data is a series of frames. With a passive socket we can just:
%% 1. read(9)
%% 2. turn that 9 into an http2 frame header
%% 3. use that header's length field L
%% 4. read(L), now we have a frame
%% 5. do something with it
%% 6. goto 1

%% Things will be different with an {active, true} socket, and also
%% different again with an {active, once} socket

%% with {active, true}, we'd have to maintain some kind of input queue
%% because it will be very likely that Data is not neatly just a frame

%% with {active, once}, we'd probably be in a situation where Data
%% starts with a frame header. But it's possible that we're here with
%% a partial frame left over from the last active stream

%% We're going to go with the {active, once} approach, because it
%% won't block the gen_server on Transport:read(L), but it will wake
%% up and do something every time Data comes in.

handle_socket_data(<<>>,
                   #connection{
                      socket=Socket
                     }=Conn) ->
    active_once(Socket),
    {keep_state, Conn};
handle_socket_data(Data,
                   #connection{
                      socket=Socket,
                      buffer=Buffer
                     }=Conn) ->
    More =
        case sock:recv(Socket, 0, 1) of %% fail fast
            {ok, Rest} ->
                Rest;
            %% It's not really an error, it's what we want
            {error, timeout} ->
                <<>>;
            _ ->
                <<>>
    end,
    %% What is buffer?
    %% empty - nothing, yay
    %% {frame, h2_frame:header(), binary()} - Frame Header processed, Payload not big enough
    %% {binary, binary()} - If we're here, it must mean that Bin was too small to even be a header
    ToParse = case Buffer of
        empty ->
            <<Data/binary,More/binary>>;
        {frame, FHeader, BufferBin} ->
            {FHeader, <<BufferBin/binary,Data/binary,More/binary>>};
        {binary, BufferBin} ->
            <<BufferBin/binary,Data/binary,More/binary>>
    end,
    %% Now that the buffer has been merged, it's best to make sure any
    %% further state references don't have one
    NewConn = Conn#connection{buffer=empty},

    case h2_frame:recv(ToParse) of
        %% We got a full frame, ship it off to the FSM
        {ok, Frame, Rem} ->
            gen_statem:cast(self(), {frame, Frame}),
            handle_socket_data(Rem, NewConn);
        %% Not enough bytes left to make a header :(
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

%% maybe_hpack will decode headers if it can, or tell the connection
%% to wait for CONTINUATION frames if it can't.
-spec maybe_hpack(#continuation_state{}, connection()) ->
                         {next_state, atom(), connection()}.
%% If there's an END_HEADERS flag, we have a complete headers binary
%% to decode, let's do this!
maybe_hpack(Continuation, Conn)
  when Continuation#continuation_state.end_headers ->
    Stream = h2_stream_set:get(
               Continuation#continuation_state.stream_id,
               Conn#connection.streams
              ),
    HeadersBin = h2_frame_headers:from_frames(
                queue:to_list(Continuation#continuation_state.frames)
               ),
    case hpack:decode(HeadersBin, Conn#connection.decode_context) of
        {error, compression_error} ->
            go_away(?COMPRESSION_ERROR, Conn);
        {ok, {Headers, NewDecodeContext}} ->
            case {Continuation#continuation_state.type,
                  Continuation#continuation_state.end_stream} of
                {push_promise, _} ->
                    Promised =
                        h2_stream_set:get(
                          Continuation#continuation_state.promised_id,
                          Conn#connection.streams
                         ),
                    recv_pp(Promised, Headers);
                {trailers, false} ->
                    rst_stream(Stream, ?PROTOCOL_ERROR, Conn);
                _ -> %% headers or trailers!
                    recv_h(Stream, Conn, Headers)
            end,
            case Continuation#continuation_state.end_stream of
                true ->
                    recv_es(Stream, Conn);
                false ->
                    ok
            end,
            {next_state, connected,
             Conn#connection{
               decode_context=NewDecodeContext,
               continuation=undefined
              }}
    end;
%% If not, we have to wait for all the CONTINUATIONS to roll in.
maybe_hpack(Continuation, Conn) ->
    {next_state, continuation,
     Conn#connection{
       continuation = Continuation
      }}.

%% Stream API: These will be moved
-spec recv_h(
        Stream :: h2_stream_set:stream(),
        Conn :: connection(),
        Headers :: hpack:headers()) ->
                    ok.
recv_h(Stream,
       Conn,
       Headers) ->
    case h2_stream_set:type(Stream) of
        active ->
            %% If the stream is active, let the process deal with it.
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, {recv_h, Headers});
        closed ->
            %% If the stream is closed, there's no running FSM
            rst_stream(Stream, ?STREAM_CLOSED, Conn);
        idle ->
            %% If we're calling this function, we've already activated
            %% a stream FSM (probably). On the off chance we didn't,
            %% we'll throw this
            rst_stream(Stream, ?STREAM_CLOSED, Conn)
    end.

-spec send_h(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_h(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% TODO: Should this be some kind of error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {send_h, Headers})
    end.

-spec send_t(
        h2_stream_set:stream(),
        hpack:headers()) ->
                    ok.
send_t(Stream, Trailers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% TODO:  Should this be some kind of error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {send_t, Trailers})
    end.

-spec recv_es(Stream :: h2_stream_set:stream(),
              Conn :: connection()) ->
                     ok | {rst_stream, error_code()}.

recv_es(Stream, Conn) ->
    case h2_stream_set:type(Stream) of
        active ->
            Pid = h2_stream_set:pid(Stream),
            h2_stream:send_event(Pid, recv_es);
        closed ->
            rst_stream(Stream, ?STREAM_CLOSED, Conn);
        idle ->
            rst_stream(Stream, ?STREAM_CLOSED, Conn)
    end.

-spec recv_pp(h2_stream_set:stream(),
              hpack:headers()) ->
                     ok.
recv_pp(Stream, Headers) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Should this be an error?
            ok;
        Pid ->
            h2_stream:send_event(Pid, {recv_pp, Headers})
    end.

-spec recv_data(h2_stream_set:stream(),
                h2_frame:frame()) ->
                        ok.
recv_data(Stream, Frame) ->
    case h2_stream_set:pid(Stream) of
        undefined ->
            %% Again, error? These aren't errors now because the code
            %% isn't set up to handle errors when these are called
            %% anyway.
            ok;
        Pid ->
            h2_stream:send_event(Pid, {recv_data, Frame})
    end.

send_request(NextId, NotifyPid, Conn, Streams, Headers, Body) ->
    case
        h2_stream_set:new_stream(
            NextId,
            NotifyPid,
            Conn#connection.stream_callback_mod,
            Conn#connection.stream_callback_opts,
            Conn#connection.socket,
            Conn#connection.peer_settings#settings.initial_window_size,
            Conn#connection.self_settings#settings.initial_window_size,
            Streams)
    of
        {error, Code, _NewStream} ->
            %% error creating new stream
            {error, Code};
        GoodStreamSet ->
            send_headers(self(), NextId, Headers),
            send_body(self(), NextId, Body),

            {ok, GoodStreamSet}
    end.

-module(h2_machine).


-include("h2_int.hrl").


-export([
    init/1,
    recv/2
]).


init(Type) when Type == client; Type == server ->
    NextStreamId = case Type of
        client -> 1;
        server -> 2
    end,
    #{
        type => Type,
        state => handshake,

        acceptor => undefined,

        send_settings => h2_settings:new(),
        recv_settings => h2_settings:new(),
        recv_settings_queue => queue:new(),

        encode_context => hpack:context(),
        decode_context => hpack:context(),

        next_stream_id => NextStreamId,
        max_peer_stream_id => 0,

        send_streams => #{active_count := 0},
        recv_streams => #{active_count := 0},

        pings => #{},
        header_acc => []
    }.


-spec recv(frame(), machine()) -> {ok | error, machine(), [frame()]}.
recv(St, Frame) ->
    #{
        state := State
    } = St,
    #{
        type := Type
    } = Frame,
    Handler = case State of
        handshake -> fun handshake/3,
        connected -> fun connected/3,
        closed -> fun closed/3,
    end,
    try
        check_state(St),
        check_frame_size(Frame, St),
        Handler(Type, St, Frame)
    catch
        throw:{?MODULE, {return, Frames}} ->
            {ok, St, Frames};
        throw:{?MODULE, {goaway, Error}} ->
            #{
                max_peer_stream_id := MPStreamId
            } = St,
            Frame = h2_frame:goaway(MPStreamId, Error)
            {error, St#{state := closed}, [Frame]};
        throw:{?MODULE, {rst_stream, StreamId, Error}} ->
            Frame = h2_frame:rst_stream(StreamId, Error),
            {ok, close_stream(StreamId, St), [Frame]}
    end.


check_state(St) ->
    #{
        state := State
    } = St,
    if State /= closed -> ok; true ->
        ?RETURN([])
    end.


check_frame_size(Frame, St) ->
    #{
        type := Type,
        length := Length
    } = Frame,
    #{
        recv_settings := #{max_frame_size := MaxFrameSize}
    } = St,
    if Length >= 16384 andalso Length =< MaxFrameSize -> ok; true ->
        % RFC 7540 Section 6.5.2
        % The initial value is 2^14 (16,384) octets. The value
        % advertised by an endpoint MUST be between this initial
        % value and the maximum allowed frame size (2^24-1 or
        % 16,777,215 octets), inclusive. Values outside this
        % range MUST be treated as a connection error (Section 5.4.1)
        % of type PROTOCOL_ERROR.
        ?CONN_ERROR(?PROTOCOL_ERROR)
    end.


handshake(settings, St, #{flags := #{ack := false}} = Frame) ->
    connected(settings, St, Frame);

handshake(_Type, St, _Frame) ->
    ?CONN_ERROR(?PROTOCOL_ERROR).


connected(settings, St0, #{flags := #{ack := false}} = Frame) ->
    #{
        send_settings := OldSettings
    } = St,
    #{
        data := NewSettings
    } = Frame,

    case h2_settings:validate(NewSettings) of
        ok -> ok;
        {error, Code} -> ?CONN_ERROR(Code)
    end,

    NewSt = update_settings(St, send, OldSettings, NewSettings),
    {ok, set_state(NewSt, connected), [h2_frame:settings_ack()]};

connected(settings, St, #{flags := #{ack := true}} = Frame) ->
    #{
        recv_settings := OldSettings,
        recv_settings_queue := SettingsQueue
    } = St,

    {NewSettings, NewQueue} = case queue:out(SettingsQueue) of
        {{value, {_Ref, NRS}}, NQ} ->
            {NRS, NQ};
        {empty, _} ->
            ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    NewSt = update_settings(St, recv, OldSettings, NewSettings),
    {ok, NewSt, []};

connected(ping, St, #{flags := #{ack := false}} = Frame) ->
    #{
        data := Data
    } = Frame,
    Frame = h2_frame:ping_ack(Data),
    {ok, St, [Frame]};

connected(ping, St, #{flags := #{ack := true}} = From) ->
    #{
        pings := Pings
    } = St,
    #{
        data := Data
    } = Frame,
    case maps:get(Data, Pings, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {'PONG', Data};
        _ ->
            ?CONN_ERROR(?PROTOCOL_ERROR)
    end,
    {ok, St, []};

connected(window_update, St0, #{stream_id := 0} = Frame) ->
    #{
        send_window_size := SWS
    } = St0,
    #{
        data := SWSIncrement
    } = Frame,

    NewSWS = SWS + SWSIncrement,
    if NewSWS =< 2147483647 -> ok; true ->
        ?CONN_ERROR(?FLOW_CONTROL_ERROR)
    end,

    St1 = St0#{
        send_window_size := NewSWS
    },

    UpdateFun = fun(Stream, {SWSAcc, FrameAcc}) ->
        case h2_stream:has_queued_data(Stream) of
            true ->
                {NewStream, DataSize, Frames}
                        = h2_stream:prepare_frames(St, Stream),
                {NewStream, {SWSAcc - DataSize, [Frames | FrameAcc]}};
            false ->
                {Stream, {SWSAcc, FrameAcc}}
        end
    end,
    {St1, {RestSWS, Frames}} = update_streams(St, send, UpdateFun, InitAcc),
    St2 = St1#{
        send_window_size := RestSWS
    },
    {ok, St2, lists:flatten(lists:reverse(Frames))};

connected(goaway, St, Frame) ->
    #{
        data := {LastStreamId, ErrorCode, Debug}
    } = Frame,


connected(headers, #{type := server}, #{stream_id := StreamId})
        when StreamId rem 2 == 0 ->
    % This case would be if a client tried to send request
    % headers on a PUSH_PROMISE'd stream. That's invalid
    % because the headers go with the promise on the
    % client initiated stream.
    ?CONN_ERROR(?PROTOCOL_ERROR);

connected(headers, St, #{flags := #{end_headers := false}} = Frame) ->
    NewSt = St#{
        state := continuation,
        header_acc := [Frame]
    },
    {ok, NewSt, []};

connected(headers, St0, Frame) ->
    handle_headers(St, Frame);

connected(data, St, Frame) ->
    #{
        stream_id := StreamId
    } = Frame,

    erlang:error(implement_recv_flow_control_check),

    update_stream(St, StreamId, fun(StreamKind, Stream) ->
        h2_stream:data(St, StreamKind, Stream, Frame)
    end);

connected(priority, St, Frame) ->
    #{
        stream_id := StreamId,
        data := Priority
    } = Frame,

    update_stream(St, StreamId, fun(Stream) ->
        h2_stream:priority(St, Stream, Priority)
    end);

connected(rst_stream, St, Frame) ->
    #{
        stream_id := StreamId,
        data := ErrorCode
    } = Frame,

    update_stream(St, StreamId, fun(Stream) ->
        h2_stream:reset(St, Stream, ErrorCode)
    end);

connected(push_promise, #{type := server}, _Frame) ->
    ?CONN_ERROR(?PROTOCOL_ERROR);

connected(push_promise, St0, #{flags := #{end_headers := false}} = Frame) ->
    St1 = St0#{
        state := continuation,
        header_acc := [Frame],
    },
    {ok, St1, []};

connected(push_promise, St0, Frame) ->
    handle_headers(St0, Frame);

connected(window_update, St0, Frame) ->
    #{
        stream_id := StreamId
    } = Frame,

    update_stream(St0, StreamId, fun(Stream) ->
        h2_stream:window_update(St0, Stream, Frame)
    end);

connected(Type, St, _Frame) when is_integer(Type) ->
    % Unknown frame type. Ignore
    {ok, St, []};

connected(_Type, St, Frame) ->
    erlang:error({unmatched_frame, St, Frame}).


continuation(continuation, St, #{flags := #{end_headers := false}} = Frame) ->
    #{
        header_acc := [Prev | _] = Acc
    } = St,
    #{
        stream_id := StreamId
    } = Frame,
    #{
        stream_id := PrevStreamId
    } = Prev,
    if StreamId == PrevStreamId -> ok; true ->
        ?CONN_ERROR(?PROTOCOL_ERROR)
    end,
    {ok, St#{header_acc := [Frame | Acc]}, []};

continuation(continuation, St0, #{flags := #{end_headers := true}} = Frame) ->
    #{
        decode_context := DecCtx,
        header_acc := [Prev | _] = Acc
    } = St0,
    #{
        type := Type,
        stream_id := StreamId
    } = Frame,
    #{
        stream_id := PrevStreamId
    } = Prev,
    if StreamId == PrevStreamId -> ok; true ->
        ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    % Combine all of our data blocks into a single
    % binary. Note that we don't reverse IoData
    % as `header_acc` is already reversed.
    IoData = lists:foldl(fun(F, DataAcc) ->
        [maps:get(data, F) | DataAcc]
    end, [], [Frame | Acc]),

    % The last frame is either the HEADERS or
    % PUSH_PROMISE that started the continuation
    % which also carries the end_stream flag.
    Base = lists:last(Acc),
    handle_headers(St, Base#{data := iolist_to_binary(IoData)});

continuation(_Type, _St, _Frame) ->
    ?CONN_ERROR(?PROTOCOL_ERROR).


handle_headers(St0, Frame0) ->
    #{
        type := ConnType,
        decode_context := DecCtx
    } = St0,
    #{
        type := FrameType,
        stream_id := StreamId,
        data := Data
        flags := #{end_stream := EndStream},
        promised_stream_id := PromisedStreamId
    } = Frame0,

    {NewCtx, Headers} = case hpack:decode(DecCtx, Data) of
        {ok, {NC, H}} -> {NC, H};
        {error, _} -> ?CONN_ERROR(?COMPRESSION_ERROR)
    end,

    St1 = St0#{
        state := connected,
        decode_context := NewCtx,
        header_acc := []
    },

    Frame1 = Frame0#{
        data := Headers
    },

    Stream = case FrameType of
        headers ->
            get_stream(St1, StreamId);
        push_promise ->
            reserve_remote_stream(St1, PromisedStreamId)
    end,

    #{
        state := StreamState
    } = Stream,

    case stream_transition(recv, StreamState, FrameType, EndStream) of



state_transitions(Action, State, FrameType, EndStream) ->
    case {Action, State, FrameType, EndStream} of
        % idle
        {recv, idle, headers, false} -> open;
        {recv, idle, headers, true} -> half_closed_remote;
        {recv, idle, priority, _} -> idle;

        {send, idle, headers, false} -> open;
        {send, idle, headers, true} -> half_closed_local;
        {send, idle, priority, _} -> idle;

        % reserved_local
        {recv, reserved_local, priority, _} -> reserved_local;
        {recv, reserved_local, rst_stream, _} -> recv_reset;
        {recv, reserved_local, window_update, _} -> reserved_local;

        {send, reserved_local, headers, false} -> half_closed_remote;
        {send, reserved_local, headers, true} -> closed;
        {send, reserved_local, priority, _} -> reserved_local;
        {send, reserved_local, rst_stream, _} -> send_reset;

        % reserved_remote
        {recv, reserved_remote, headers, false} -> half_closed_local;
        {recv, reserved_remote, headers, true} -> closed;

        {send, reserved_remote, priority, _} -> reserved_remote;
        {send, reserved_remote, rst_stream, _} -> send_reset;
        {send, reserved_remote, window_update, _} -> reserved_remote;

        % open
        {recv, open, rst_stream, _} -> recv_reset;
        {recv, open, _, false} -> open;
        {recv, open, _, true} -> half_closed_remote;

        {send, open, rst_stream, _} -> send_reset;
        {send, open, _, false} -> open;
        {send, open, _, true} -> half_closed_local;

        % half_closed_local
        {recv, half_closed_local, rst_stream, _} -> closed;
        {recv, half_closed_local, _, false} -> half_closed_local;
        {recv, half_closed_local, _, true} -> closed;

        {send, half_closed_local, priority, _} -> half_closed_local;
        {send, half_closed_local, rst_stream, _} -> send_reset;
        {send, half_closed_local, window_update, _} -> half_closed_local;

        % half_closed_remote
        {recv, half_closed_remote, priority, _} -> half_closed_remote;
        {recv, half_closed_remote, rst_stream, _} -> closed;
        {recv, half_closed_remote, window_update, _} -> half_closed_remote;
        {recv, half_closed_remote, _, _} -> {stream_error, ?STREAM_CLOSED};

        {send, half_closed_remote, rst_stream, _} -> closed;
        {send, half_closed_remote, _, false} -> half_closed_remote;
        {send, half_closed_remote, _, true} -> closed;

        % The closed state as described in RFC 7540 Section 5.1
        % is actually *at least* three different states. These
        % are broken out so that the state transitions can be
        % 100% data driven.

        % closed - Really closed and both sides should know it
        {recv, closed, priority, _} -> closed;
        {recv, closed, rst_stream, _} -> closed;
        {recv, closed, window_update, _} -> closed;
        {recv, closed, _, _} -> {conn_error, ?PROTOCOL_ERROR};

        {send, closed, priority, _} -> closed;

        % recv_reset - We received a rst_stream
        {recv, recv_reset, priority, _} -> recv_reset;
        {recv, recv_reset, _, _} -> {stream_error, ?STREAM_CLOSED};

        {send, recv_reset, priority, _} -> recv_reset;

        % send_reset - We sent a rst_stream, ignore anything
        % that doesn't transition us to a closed state
        {recv, send_reset, rst_stream, _} -> closed;
        {recv, send_reset, _, true} -> clsoed;
        {recv, send_reset, _, _} -> send_reset;

        {send, send_reset, priority, _} -> send_reset;

        % Catch-all
        _ -> {conn_error, ?PROTOCOL_ERROR}
    end.



close_stream(StreamId, St) ->
    #{
        streams := Streams
    } = St,
    case maps:get(StreamId, Streams, undefined) of
        undefined ->
            St;
        Stream ->
            update_stream(St, Stream#{state := closed})
    end.


update_settings(St, Which, OldSettings, NewSettings) ->
    #{
        header_table_size := OldHTS,
        initial_window_size := OldIWS
    } = OldSettings,
    HdrCtxKey = case Which of
        send -> encode_context;
        recv -> decode_context
    end,

    % RFC 7540 Section 6.5.3
    % The values in the SETTINGS frame MUST be processed
    % in the order they appear, with no other frame
    % processing between values.

    lists:foldl(fun
        ({header_table_size, OldHTS}, StAcc) ->
            % No change, nothing to update.
            StAcc;
        ({header_table_size, NewHTS}, StAcc) ->
            OldCtx = maps:get(HdrCtxKey, St),
            NewCtx = hpack:set_max_conn_size(OldCtx, NewHTS),
            StAcc1 = StAcc#{HdrCtxKey := NewCtx},
            update_setting(StAcc1, Which, header_table_size, NewHTS),
        ({initial_window_size, OldIWS}, StAcc) ->
            % No change, nothing to update.
            StAcc;
        ({initial_window_size, NewIWS}, StAcc) ->
            IWSDelta = NewIWS - OldIws
            {StAcc1, _} = update_streams(St, Which, fun(Stream, _) ->
                StreamSWS = maps:get(send_window_size, Stream),
                NewStream = Stream#{send_window_size := StreamSWS + IWSDelta},
                {NewStream, nil}
            end, nil),
            update_setting(StAcc1, Which, initial_window_size, NewIWS)
        ({Setting, Value}) ->
            update_setting(StAcc, Which, Setting, Value)
    end, St, NewSettings).


update_streams(St, Which, UserFun, UserAcc) ->
    StreamSetKey = case Which of
        send -> send_streams;
        recv -> recv_streams
    end,

    StreamSet = maps:get(StreamSetKey, St),
    Streams = maps:get(streams, StreamSet),

    FoldFun = fun(StreamId, Stream, {StreamAcc, UserAcc1}) ->
        {NewStream, UserAcc2} = UserFun(Stream, UserAcc1),
        NewStreamAcc = maps:put(StreamId, NewStream, StreamAcc),
        {NewStreamAcc, UserAcc2}
    end,
    {NewStreams, UserAcc3} = maps:fold(FoldFun, {Streams, UserAcc}, Streams),

    NewStreamSet = maps:put(streams, NewStreams, StreamSet),
    NewSt = maps:put(StreamSetKey, NewStreamSet, NewStreamSet),
    {NewSt, UserAcc3}.


get_stream(#{type := server} = St, StreamId) when StreamId rem 2 == 0 ->
    get_stream(St, send_streams, StreamId);
get_stream(#{type := server} = St, StreamId) ->
    get_stream(St, recv_streams, StreamId);
get_stream(#{type := client} = St, StreamId) when StreamId rem 2 == 1 ->
    get_stream(St, send_streams, StreamId);
get_stream(#{type := client} = St, StreamId) ->
    get_stream(St, recv_streams, StreamId).


get_stream(St, StreamSetKey, StreamId) ->
    #{
        send_settings := #{initial_window_size := SWS},
        recv_settings := #{initial_window_size := RWS}
    } = St,

    Direction = case StreamSetKey of
        send_streams -> send;
        recv_streams -> recv
    end,

    StreamSet = maps:get(StreamSetKey, St),
    Streams = maps:get(streams, StreamSet),
    MaxStreamId = maps:get(max_stream_id, StreamSet),

    case maps:get(StreamId, Streams, undefined) of
        undefined when StreamId > MaxStreamId ->
            h2_stream:new(StreamId, idle, Direction, SWS, RWS);
        undefined ->
            h2_stream:new(StreamId, closed, Direction, SWS, RWS);
        #{} = Stream ->
            Stream
    end.


reserve_remote_stream(St, StreamId) ->
    #{
        state := State
    } = Stream = get_stream(St, StreamId),
    if State /= idle -> Stream; true ->
        Stream#{
            state := reserved_remote
        }
    end.

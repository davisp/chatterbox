-module(h2_stream_set).

-export([
    new/1,
    new_stream/3,
    reset/2,

    handle_data/4,
    handle_send_window_update/3,

    queue/4,
    flush/2
]).


-include("h2.hrl").


-spec new(client | server) -> h2:stream_set().
new(Type, SendSettings, RecvSettings) ->
    {LocalStart, RemoteStart} = case Type of
        client -> {1, 2};
        server -> {2, 1}
    end,
    #stream_set{
        type = Type,

        send_settings = SendSettings,
        recv_settings = RecvSettings,

        recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE,
        send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE,

        local = #{
            streams => #{},
            oldest_id => 0,
            next_id = LocalStart,
            active = 0
        },

        remote = #{
            streams => #{},
            oldest_id => 0,
            next_id = RemoteStart,
            active = 0
        }
    }.


-spec new_stream(h2:stream_set(), pid(), [stream_opt()]) ->
        {ok, h2:stream_set(), h2:stream()} | {error, term()}.
new_stream(#stream_set{type = client} = StreamSet, Pid, Opts) ->
    #stream_set{
        send_settings = #settings{
            initial_window_size = SWSize,
            max_concurrent_streams = MaxActive
        },
        recv_sttings = #settings{
            initial_window_size = RWSize
        },

        local = Group = #{
            streams := Streams,
            next_id := NextId,
            active := Active
        }
    } = Streams,

    Async = case proplists:get_value(async, Opts) of
        true -> true;
        _ -> false
    end,

    State = case proplists:get_value(end_stream, Opts) of
        true -> half_closed_local;
        _ -> open
    end,

    case Active < MaxActive of
        true ->
            Stream = h2_stream:new(NextId, State, Pid, Async, SWSize, RWSize),
            NewStreamSet = StreamSet#stream_set{
                local := Local#{
                    streams := maps:put(StreamId, Stream, Streams),
                    next_id := NextId + 2,
                    active := Active + 1
                }
            },
            {ok, NewStreamSet, NextId}
        false ->
            {error, ?REFUSED_STREAM}
    end.


-spec reset(stream_set(), stream_id(), error_code()) -> {ok, stream_set()}.
reset(#stream_set{} = Streams, StreamId, ErrorCode) ->
    Stream = get_stream(Streams, StreamId),
    case get_stream(Streams, StreamId) of
        #{state := idle} ->
            ?CONN_ERROR(?PROTOCOL_ERROR);
        Stream ->
            NewStream = h2_stream:reset(Stream, ErrorCode),
            update_streams(Streams, NewStream)
    end.


-spec handle_headers(stream_set(), stream_id(), headers(), boolean()) ->
        {ok, stream_set()}.
handle_headers(Streams, StreamId, Headers, EndStream) ->
    Stream = get_stream(Streams, StreamId),
    NewStream = h2_stream:handle_headers(Stream, Headers, EndStream),
    {ok, update_streams(Streas, NewStream)}.


-spec handle_data(stream_set(), stream_id(), binary()) ->
        {ok, stream_set()} | {error, error_code()}.
handle_data(#stream_set{} = Streams0, StreamId, Frame, FlowControl) ->
    #stream_set{
        recv_window_size = ConnRecvWindow
    } = Streams0,

    #{
        recv_window_size := StreamRecvWindow
    } = Stream1 = get_stream(Streams0, StreamId),

    #frame{
        length = Length,
        data = Data
    } = Frame,

    if Length =< ConnRecvWindow -> ok; true ->
        ?CONN_ERROR(?FLOW_CONTROL_ERROR)
    end,

    if Length =< StreamRecvWindow -> ok; true ->
        ?CONN_ERROR(?FLOW_CONTROL_ERROR)
    end,

    case h2_stream:handle_data(Stream, Frame) of
        {ok, Stream2} ->
            Streams1 = Streams0#stream_set{
                recv_window_size = ConnRecvWindow - Length
            },
            Streams2 = update_streams(Streams1, Stream2),

            case FlowControl of
                auto ->
                    F1 = h2_frame:window_update(0, Length),
                    F2 = h2_frame:window_update(StreamId, Length),
                    {Streams2, [F1, F2]};
                false ->
                    {Streams2, []}
            end.
        {error, Code} ->
            Streams1 = Streams0#stream_set{
                recv_window_size = ConnRecvWindow - Length,
            },
            {Streams1, [h2_frame:rst_stream(StreamId, Code)]}
    end.


handle_send_window_update(Streams, 0, Increment) ->
    #stream_set{
        send_window_size = OldSendWindow
    } = Streams,

    NewSendWindow = OldSendWindow + Increment,

    if NewSendWindow =< 2147483647 -> ok; true ->
        ?CONN_ERROR(?FLOW_CONTROL_ERROR)
    end,

    Streams#stream_set{
        send_window_size = NewSendWindow
    };

handle_send_window_update(Streams, StreamId, Increment) ->
    Stream1 = get_stream(Streams, StreamId),
    case h2_stream:handle_send_window_update(Stream1, Increment) of
        {ok, Stream2} ->
            {update_streams(Streams, Stream2),  []};
        {error, Code} ->
            {Streams, [h2_frame:rst_stream(StreamId, Code)]}
    end.


-spec queue(h2:stream_set(), stream_id(), iodata(), [send_opt()]) ->
        {ok, h2:stream_set()} | {error, term()}.
queue(#stream_set{} = Streams, StreamId, Data, Opts) ->
    Stream = get_stream(Streams, StreamId),
    case h2_stream:queue(Stream, Data, Opts) of
        {ok, NewStream} ->
            {ok, update_stream(Streams, NewStream)};
        {error, _} = Error ->
            Error
    end.


-spec flush(h2:stream_set())
        -> {ok, h2:stream_set(), [h2:frame()]} | {error, term()}.
flush(Streams0) ->
    #stream_set{
        local = #{streams := Local},
        remote = #{streams := Remote}
    } = Streams0,

    AllStreamIds = lists:sort(maps:keys(Local) ++ maps:keys(Remote)),

    {Streams1, Frames} = try
        {OutSAcc, OutFAcc} = lists:foldl(fun(StreamId, {SAcc, FAcc}) ->
            case flush(SAcc, StreamId) of
                {ok, #stream_set{send_window_size = 0} = NewSAcc, NewFrames} ->
                    throw({done, NewSAcc, lists:reverse(FAcc, NewFrames)});
                {ok, NewSAcc, NewFrames} ->
                    {NewSAcc, lists:reverse(NewFrames) ++ FAcc}
            end
        end, {Streams, []}, AllStreamIds),
        {OutSAcc, lists:reverse(OutFAcc)}
    catch throw:{done, TStreams, TFrames} ->
        {TStreams, TFrames}
    end,

    {ok, Streams1, Frames}.


-spec flush(h2:stream_set(), stream_id()) ->
        {ok, h2:stream_set(), [h2:frame()]} | {error, term()}.
flush(#stream_set{} = Streams0, StreamId) ->
    #stream_set{
        send_window_size = ConnSendWindow,
        send_settings = #settings{
            max_frame_size = MaxFrameSize
        },
    },
    Stream = get_stream(Streams0, StreamId),
    case h2_stream:dequeue(Stream, ConnSendWindow, MaxFrameSize) of
        {ok, Stream, []} ->
            no_data;
        {ok, NewStream, [#frame{type := ?DATA} | _] = Frames} ->
            #frame{
                length = Length
            } = Frame,
            Streams1 = update_streams(Streams0, NewStream),
            Streams2 = update_window_size(Streams1, Length)
            {ok, Streams2, Frames};
        {ok, NewStream, [#frame{type := ?HEADERS} | _] = Frames} ->
            Streams1 = update_streams(Streams0, NewStream),
            {ok, Streams1, Frames};
        {error, _} = Error ->
            Error
    end.


get_group(#stream_set{} = Streams, StreamId) ->
    #stream_set{
        type = Type,
        local = Local,
        remote = Remote
    } = Streams,
    case {Type, StreamId rem 2 == 0} ->
        {client, false} -> {local, Local};
        {client, true} -> {remote, Remote};
        {server, true} -> {local, Local};
        {server, false} -> {remote, Remote}
    end.


get_stream(#stream_set{} = Streams, StreamId) ->
    {_, Group} = get_group(Streams, StreamId),
    #{
        streams := GroupStreams,
        next_id := NextId
    } = Group,
    case maps:get(StreamId, GroupStreams, undefined) of
        #{} = Stream ->
            Stream;
        undefined when StreamId >= NextId ->
            h2_stream:new(StreamId, idle);
        undefined when StreamId < NextId ->
            h2_stream:new(StreamId, closed)
    end.


update_stream(#stream_set{} = Streams, #{} = Stream) ->
    #{
        id := StreamId
        state := State
    } = Stream,
    {GroupName, Group} = get_group(Streams, StreamId),
    #{
        streams = GroupStreams,
        active = Active
    } = Group,
    NewActive = case State of
        closed -> Active - 1;
        _ -> Active
    end,
    NewGroup = Group#{
        streams := maps:put(StreamId, Stream, GroupStreams),
        active := NewActive
    },
    Streams#stream_set{
        GroupName := NewGroup
    }.

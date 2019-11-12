-module(h2_stream).


% User API
-export([
    send/2,
    send/3,

    recv/1
]).


% Internal API
-export([
    new/2,
    new/6,

    reset/2,

    handle_event/3,

    queue/3,
    dequeue/3
]).


send(#{id := Id, pid := Pid}, Data) when is_binary(Data) ->
    gen_statem:call(Pid, {stream_send, Id, Data, []}).


send(#{id := Id, pid := Pid}, Data, Opts) ->
    gen_statem:call(Pid, {stream_send, Id, Data, Opts}).


recv(#{} = Stream) ->
    recv(Stream, 5000).


recv(#{id := Id, pid := Pid}, Timeout) ->
    receive
        {Id, Pid, resp, Resp} ->
            {ok, Resp};
        {Id, Pid, headers, Resp} ->
            {ok, Resp};
        {Id, Pid, data, Data} ->
            {data, Data};
        {Id, Pid, trailers, Trailers} ->
            {trailers, Trailers};
        {Id, Pid, closed} ->
            closed;
        {Id, Pid, error, Error} ->
            {error, Error}
    end.


new(StreamId, State) ->
    new(StreamId, State, undefined, false, 0, 0).


new(StreamId, State, ControllingPid, Async, SendWindowSize, RecvWindowSize) ->
    Type = case StreamId rem 2 == 0 of
        true -> server;
        false -> client
    end,
    #{
        id => StreamId,
        state => State,
        type => Type,
        controlling_pid => ControllingPid,
        async => Async,
        send_queue => queue:new(),
        send_window_size => SendWindowSize,
        recv_window_size => RecvWindowSize,
        resp => undefined,
        error => undefined
    }.


handle_event(Stream, Event, Msg) ->
    #{
        state := State
    } = Stream,

    Handle = case State of
        idle -> fun idle/3,
        reserved_local -> fun reserved_local/3,
        reserved_remote -> fun reserved_remote/3,
        open -> fun open/3,
        half_closed_local -> fun half_closed_local/3,
        half_closed_remote -> fun half_closed_remote/3,
        closed -> fun closed/3
    end,

    Handle(Stream, Event, Msg).



idle(Stream, _Event, _Msg) ->
    #{
        stream_id := StreamId
    } = Stream,
    ?STREAM_ERROR(StreamId, ?PROTOCOL_ERROR).


open(#{resp := undefined} = Stream, headers, {RawHeaders, EndStream}) ->
    Resp1 = h2_headers:handle_resp_headers(RawHeaders),
    Resp2 = case Async of
        true ->
            send(Stream, headers, Resp1);
            async;
        false when EndStream ->
            send(Stream, headers, Resp1#{body => <<>>});
        false ->
            Resp1
    end,

    Stream#{
        resp := Resp2
    };

open(#{resp,})



reset(Stream, ErrorCode) ->
    #{
        stream_id := StreamId,
        controlling_pid := ControllingPid,
        resp := Resp
    },
    case is_pid(ControllingPid) and not Resp == complete of
        true ->
            ControllingPid ! {StreamId, self(), error, ErrorCode};
        false ->
            ok
    end,
    Stream#{
        state := closed,
        send_queue := queue:new(),
        resp := complete,
        error := ErrorCode
    }.


handle_headers(#{type := client, state := State} = Stream, Headers, EndStream)
        when State == open; State == half_closed_local ->
    #{
        resp := Resp
    } = Stream,

    case {Resp, EndStream} of
        {undefined, false} -> ok;
        {#{}, true} -> ok;
        {async, true} -> ok;
        _ -> ?STREAM_ERROR(?PROTOCOL_ERROR)
    end,

    case EndStream of
        true -> handle_resp_headers(Stream, Headers);
        false -> handle_resp_trailers(Stream, Headers)
    end;

handle_headers(Stream, _Headers, _EndStream) ->
    #{
        stream_id := StreamId
    } = Stream,
    ?STREAM_ERROR(StreamId, ?STREAM_CLOSED).


handle_resp_headers(Stream, RawHeaders) ->
    #{
        stream_id := StreamId,
        controlling_pid := ControllingPid
        async := Async,
        resp := undefined
    } = Stream,

    {Status, Headers} = h2_headers:handle_resp_headers(RawHeaders),

    Resp = #{
        status => Status,
        headers => Headers
    },

    NewResp = case Async of
        true ->
            ControllingPid ! {StreamId, self(), headers, Resp};
            async;
        false ->
            Resp
    end,

    {ok, Stream#{
        resp := NewResp
    }}.


handle_resp_trailers(Stream, RawHeaders) ->
    #{
        stream_id := StreamId,
        state := State,
        controlling_pid := ControllingPid
        async := Async,
        resp := Resp
    } = Stream,

    Trailers = h2_headers:handle_resp_trailers(RawHeaders),

    NewResp = case Async of
        true ->
            ControllingPid ! {StreamId, self(), trailers, Trailers};
        false ->
            FinalResp = Resp#{trailers => Trailers},
            ControllingPid ! {StreamId, self(), resp, FinalResp}
    end,

    NewState = case State of
        open -> half_closed_remote;
        half_closed_local -> closed
    end,

    {ok, Stream#{
        state := NewState,
        resp := complete
    }}.

handle_data(#{state := State} = Stream, Frame)
        when State == open; State == half_closed_local ->
    #{
        stream_id := StreamId,
        state := State,
        controlling_pid := ControllingPid,
        async := Async,
        recv_window_size := RecvWindow,
        resp := Resp
    } = Stream,

    #frame{
        length = Length,
        flags = Flags,
        data = Data
    } = Frame,

    EndStream = ?IS_FLAG(Flags, ?END_STREAM),

    NewResp = case Async of
        true -> handle_async_data(Stream, Data, EndStream);
        false -> handle_sync_data(Stream, Data, EndStream)
    end,

    NextState = case {State, EndStream} of
        {open, true} ->
            half_closed_remote;
        {half_closed_local, true} ->
            closed;
        _ ->
            State
    end,

    {ok, Stream#{
        state := NextState,
        recv_window_size := RecvWindow - Length,
        resp := NewResp
    }};

handle_data(#{} = Stream, _Frame) ->
    {error, ?STREAM_CLOSED}.


handle_async_data(Stream, Data, EndStream) ->
    #{
        stream_id := StreamId,
        controlling_pid := ControllingPid
    } = Stream,
    ControllingPid ! {StreamId, self(), data, Data},
    case EndStream of
        true ->
            ControllingPid ! {StreamId, self(), closed},
            complete;
        false ->
            async
    end.


handle_sync_data(Stream, Data, EndStream) ->
    #{
        stream_id := StreamId,
        controlling_pid := ControllingPid,
        resp := Resp0
    } = Stream,

    Resp1 = queue_resp(Resp0, Data),
    case EndStream of
        true ->
            Resp2 = finalize_resp(Resp1),
            ControllingPid ! {StreamId, self(), resp, Resp2},
            complete;
        false ->
            Resp1
    end.


handle_send_window_update(#{} = Stream, Increment) ->
    #{
        state := State,
        send_window_size := OldSendWindow
    } = Stream,

    case State of
        open -> ok;
        half_closed_local -> ok;
        half_closed_remote -> ok;
        closed -> ok;
        _ -> ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    NewSendWindow = OldSendWindow + Increment,

    if NewSendWindow =< 2147483647 -> ok; true ->
        ?CONN_ERROR(?FLOW_CONTROL_ERROR)
    end,

    {ok, Stream#{
        send_window_size = NewSendWindow
    }}.


queue(#{} = Stream, Data, Opts) ->
    #{
        state := State,
        send_queue := Queue
    } = Stream,
    EndStream0 = case proplists:get_value(end_stream, Opts) of
        true -> true;
        _ -> false
    end,
    {EndStream, Trailers} = case lists:keyfind(trailers, 1, Opts) of
        {trailers, T} when is_list(T) ->
            {true, T};
        false ->
            {EndStream0, no_trailers}
    end,
    case State of
        open when not EndStream ->
            {ok, Stream#{
                send_queue := queue_in(Data, Trailers, Queue),
            }}
        open when EndStream ->
            {ok, Stream#{
                state := half_closed_local,
                send_queue := queue_in(Data, Trailers, Queue),
            }};
        half_closed_remote when not EndStream ->
            {ok, Stream#{
                send_queue := queue_in(Data, Trailers, Queue),
            }};
        half_closed_remote when EndStream ->
            {ok, Stream#{
                state := closed
                send_queue := queue_in(Data, Trailers, Queue)
            }};
        closed ->
            {error, ?STREAM_CLOSED};
        _ ->
            {error, ?PROTOCOL_ERROR}
    end.


queue_in(Data, Trailers, Queue0) ->
    Queue1 = case iolist_size(Data) of
        0 -> Queue0;
        _ -> queue:in(Data, Queue0)
    end,
    case Trailers of
        no_trailers -> Queue1;
        Trailers -> queue:in({trailers, Trailers}, Queue1)
    end.


dequeue(Stream, ConnSendWindow, MaxFrameSize) ->
    #{
        stream_id := StreamId,
        state := State,
        send_queue := Queue,
        send_window_size := StreamSendWindow,
    } = Stream,

    MaxToSend = lists:min([ConnSendWindow, StreamSendWindow, MaxFrameSize]),
    {DataBin, NewQueue} = dequeue_data(Queue, MaxToSend),

    Next = case queue:peek(NewQueue) of
        {value, {trailers, _} = T} ->
            T;
        {value, _IoData} ->
            data;
        empty when State == closed; State == half_closed_local ->
            end_stream;
        empty when State == open; State == half_closed_remote ->
            open
        empty ->
            ?CONN_ERROR(?PROTOCOL_ERROR)
    end,

    Flags = case Next of
        end_stream -> ?END_STREAM;
        _ -> 0
    end,

    Frames = case size(DataBin) > 0 of
        true ->
            Frame0 = h2_frame:data(Flags, StreamId, DataBin),
            case Next of
                {trailers, TFrames} -> [Frame0 | TFrames];
                _ -> [Frame0]
            end;
        false ->
            case Next of
                {trailers, TFrames} -> TFrames;
                _ -> []
            end
    end,

    NewStream = Stream#{
        send_queue := NewQueue,
        send_window_size := StreamSendWindow - size(DataBin)
    },
    {ok, NewStream, Frames}.


dequeue_data(Queue, MaxToSend) ->
    dequeue_data(Queue, MaxToSend, []).


dequeue_data(Queue, 0, Acc) ->
    Bin = iolist_to_binary(lists:reverse(Acc)),
    {Bin, Queue};

dequeue_data(Queue, MaxToSend, Acc) when MaxToSend > 0 ->
    case queue:peek(Queue) of
        {value, {trailers, _}} ->
            dequeue_data(Queue, 0, Acc);
        {value, IoData} ->
            {{value, IoData}, NewQueue} = queue:out(Queue),
            Size = iolist_size(IoData),
            case Size =< MaxToSend of
                true ->
                    dequeue_data(NewQueue, MaxToSend - Size, [IoData | Acc]);
                false ->
                    Bin = iolist_to_binary(IoData),
                    <<ToSend:MaxToSend/binary, Rest/binary>> = Bin,
                    Requeued = queue:in_r(Rest, NewQueue),
                    dequeue_data(Requeued, 0, [ToSend | Acc])
            end;
        empty ->
            dequeue_data(Queue, 0, Acc)
    end.


queue_resp(#{body := Acc} = Resp, Data) ->
    Resp#{
        body := [Data | Acc]
    };

queue_resp(#{} = Resp, Data) ->
    Resp#{
        body => [Data]
    }.


finalize_resp(#{body := Acc} = Resp) ->
    Resp#{
        body := lists:reverse(Acc)
    };

finalise_resp(#{} = Resp) ->
    Resp#{
        body := <<>>
    }.


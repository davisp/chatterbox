-module(h2_frame).

-include("h2.hrl").

-export([
    recv/1,
    render/1
]).


-spec recv(binary() | {frame(), binary()}) ->
        {ok, frame(), binary()} |
        {more, binary()} |
        {more, header(), binary()} |
        {error, stream_id(), error_code(), binary()}.
recv(Bin) when is_binary(Bin), byte_size(Bin) < 9 ->
    {more, Bin};
recv(Bin) when is_binary(Bin) ->
    {InitFrame, RestBin} = recv_frame_header(Bin),
    recv({InitFrame, RestBin});
recv({Frame, Bin}) when byte_size(Bin) < Frame#frame.length ->
    {more, Frame, Bin};
recv({#frame{type = Type} = Frame, Bin}) ->
    case Type of
        ?DATA -> recv_data(Frame, Bin);
        ?HEADERS -> recv_headers(Frame, Bin);
        ?PRIORITY -> recv_priority(Frame, Bin);
        ?RST_STREAM -> recv_rst_stream(Frame, Bin);
        ?SETTINGS -> recv_settings(Frame, Bin);
        ?PUSH_PROMISE -> recv_push_promise(Frame, Bin);
        ?PING -> recv_ping(Frame, Bin);
        ?GOAWAY -> recv_goaway(Frame, Bin);
        ?WINDOW_UPDATE -> recv_window_update(Frame, Bin);
        ?CONTINUATION -> recv_continuation(Frame, Bin);
        _Unknown -> recv_unknown(Frame, Bin)
    end.


-spec send(any(), h2:frame()) -> ok | {error, inet:posix()}.
render(#frame{} = Frame) ->
    render([Frame]);

render(Frames) when is_list(Frames) ->
    IoData = lists:map(fun(Frame) ->
        render_frame(Frame)
    end, Frames),
    sock:send(Socket, IoData).


recv_frame_header(Bin) ->
    <<
        Length:24,
        Type:8,
        Flags:8,
        _R:1,
        StreamId:31,
        Rest/binary
    >> = Bin,
    Frame = #frame{
        length = Length,
        type = Type,
        flags = Flags,
        stream_id = StreamId
    },
    {Frame, Rest}.


recv_data(#frame{stream_id = 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv_data(#frame{length = 0} = Frame, _Bin) ->
    {ok, Frame#frame{data = <<>>}, Bin};
recv_data(Frame, Bin) ->
    #frame{
        length = Length,
        stream_id = StreamId
    } = Frame,
    <<MaybePadded:Length/binary, Rest/binary>> = Bin,
    case h2_padding:depad(Frame, MaybePadded) of
        {ok, Data} ->
            {ok, Frame#frame{data = Data}, Rest}
        {error, Code} ->
            {error, StreamId, Code, Rest}
    end.


recv_headers(#frame{stream_id = 0}, _) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv_headers(Frame, Bin) ->
    #frame{
        length = Length,
        flags = Flags,
        stream_id = StreamId
    } = Frame,
    <<MaybePadded:Length/binary, Rest/binary>> = Bin,
    case h2_padding:depad(Frame, MaybePadded) of
        {ok, Data} ->
            {Priority, RestData} = case ?IS_FLAG(Flags, ?PRIORITY) of
                true ->
                    h2_priority:read(Data);
                false ->
                    {#priority{}, Data}
            end,
            {ok, Frame#frame{data = {Priority, RestData}}, Rest};
        {error, Code} ->
            {error, Frame#frame.stream_id, Code, Rest}
    end.


recv_priority(#frame{stream_id = 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv_priority(#frame{length = Length}, Bin) when Length /= 5 ->
    <<_:Length/binary, Rest/binary>> = Bin,
    #frame{
        stream_id = StreamId
    } = Frame,
    {error, StreamId, ?FRAME_SIZE_ERROR, Rest};
recv_priority(Frame, Bin) ->
    #frame{
        stream_id =StreamId
    } = Frame,
    {Priority, Rest} = h2_priority:read(Bin),
    {ok, Frame#frame{data = Priority}, Rest}.


recv_rst_stream(#frame{stream_id = 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv_rst_stream(#frame{length = Length}, _Bin) when Length /= 4 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv_rst_stream(Frame, Bin) ->
    <<ErrorCode:32, Rest/binary>> = Bin,
    {ok, Frame#frame{data = ErrorCode}, Rest}.


recv_settings(#frame{length = Length}, _Bin) when Length rem 6 /= 0 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv_settings(#frame{stream_id = 0, length = 0} = Frame, Bin) ->
    {ok, Frame#frame{data = #settings{}}, Bin};
recv_settings(#frame{stream_id = 0} = Frame, Bin) ->
    #frame{
        length = Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    Settings = parse_settings(Data, []),
    {ok, Frame#frame{data = Settings}, Rest};
recv_settings(_Frame, _Bin) ->
    % Invalid stream_id for settings frame
    {error, 0, ?PROTOCOL_ERROR, <<>>}.


parse_settings(<<>>, Acc) ->
    lists:reverse(Acc);

parse_settings(Bin, Acc) ->
    <<Key:16, Value:4/binary, Rest/binary>> = Bin,
    case lists:member(Key, ?KNOWN_SETTINGS) of
        true ->
            NewAcc = [{Key, binary:decode_unsigned(Value)} | Acc],
            parse_settings(Rest, NewAcc);
        false ->
            parse_settings(Rest, Acc)
    end.


recv_push_promise(#frame{stream_id = 0}, Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv_push_promise(Frame, Bin) ->
    #frame{
        length = Length,
        stream_id = StreamId
    } = Frame,
    <<MaybePadded:Length/binary, Rest/binary>> = Bin,
    case h2_padding:depad(Frame, MaybePadded) of
        {ok, Data} ->
            <<_R:1, StreamId:31, RestData/binary>> = Data,
            {ok, Frame#fraome{data = {StreamId, RestData}}, Rest};
        {error, Code} ->
            {error, StreamId, Code, Rest}
    end.


recv_ping(#frame{length = Length}, Bin) when Length /= 8 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv_ping(#frame{stream_id = 0}, Bin) ->
    <<Data:8/binary, Rest/binary>> = Bin,
    {ok, Frame#frame{data = Data}, Rest};
recv_ping(_Frame, _Bin) ->
    % Invalid stream_id for ping
    {error, 0, ?PROTOCOL_ERROR, <<>>}.


recv_goaway(#frame{stream_id = 0} = Frame, Bin) ->
    #frame{
        length = Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    <<_R:1, LastStreamId:31, ErrorCode:32, Extra/binary>> = Data,
    {ok, Frame#frame{data = {LastStreamId, ErrorCode, Debug}}, Rest};
recv_goaway(_Frame, _Bin) ->
    % Invalid stream_id for goaway
    {error, 0, ?PROTOCOL_ERROR, <<>>}.


recv_window_update(#frame{length = Lengty}, _Bin) when Length /= 4 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv_window_update(Frame, <<_R:1, 0:31, Rest/binary>>) ->
    #frame{
        stream_id = StreamId
    } = Frame,
    {error, StreamId, ?PROTOCOL_ERROR, Rest};
recv_window_update(Frame, Bin) ->
    <<_R:1, Increment:31, Rest/binary>> = Bin,
    {ok, Frame#frame{data = Increment}, Rest}.


recv_continuation(#frame{stream_id = 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv_continuation(Frame, Bin) ->
    #frame{
        length = Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    {ok, Frame#frame{data = Data}, Rest}.


recv_unknown(Frame, Bin) ->
    #frame{
        length = Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    {ok, Frame#frame{data = Data}, Rest}.


render_frame(Frame) ->
    #frame{
        type = Type,
        flags = Flags,
        stream_id = StreamId,
        data = Data
    } = Frame,
    IoData = case Type of
        ?DATA -> render_data(Data);
        ?HEADERS -> render_headers(Flags, Data);
        ?PRIORITY -> render_priority(Data);
        ?RST_STREAM -> render_rst_stream(Data);
        ?SETTINGS -> render_settings(Data);
        ?PUSH_PROMISE -> render_push_promise(Data);
        ?PING -> render_ping(Data);
        ?GOAWAY -> render_goaway(Data);
        ?WINDOW_UPDATE -> render_window_update(Data);
        ?CONTINUATION -> render_continuation(Data);
        _Unknown -> render_unknown(Data)
    end,
    Length = erlang:iolist_size(IoData),
    Header = <<
        Length:24,
        Type:8,
        Flags:8,
        _R:1,
        StreamId:31
    >>,
    [Header, IoData].


render_data(Data) when is_binary(Data) ->
    Data.


render_headers(Flags, {#priority{} = Priority, Data}) when is_binary(Data) ->
    case ?IS_FLAG(Flags, Priority) of
        true ->
            [h2_priority:render(Priority), Data];
        false ->
            Data
    end.


render_priority(#priority{} = Priority) ->
    h2_priority:render(Priority).


render_rst_stream(ErrorCode)
        when is_integer(ErrorCode), ErrorCode >= 0 ->
    <<ErrorCode:32>>.


render_settings(Settings) when is_list(Settings) ->
    lists:map(fun({Key, Value}) ->
        <<Key:16, Value:32/unsigned>>
    end, Settings).


render_push_promise({StreamId, Data}) when is_integer(StreamId), StreamId > 0 ->
    <<0:1, StreamId:31, Data/binary>>.


render_ping(Data) when is_binary(Data), size(Data) == 8 ->
    Data.


render_goaway({LastStreamId, ErrorCode, Debug})
        when is_integer(LastStreamId), LastStreamId > 0,
            is_integer(ErrorCode), ErrorCode > 0 ->
    <<0:1, LastStreamId:31, ErrorCode:32, Debug/binary>>.


render_window_update(Increment) when is_integer(Increment), Increment > 0 ->
    <<0:1, Increment:31>>.


render_continuation(Data) when is_binary(Data) ->
    Data.


render_unknown(Data) when is_binary(Data) ->
    Data.

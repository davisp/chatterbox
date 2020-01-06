-module(h2_frame).

-include("h2_int.hrl").


-export([
    recv/1,
    render/1,

    new/1,
    new/2,
    new/3,

    rst_stream/2,
    settings_ack/0,
    goaway/1,
    window_update/2,

    set_flag/2
]).


-spec recv(binary() | {frame(), binary()}) ->
        {ok, frame(), binary()} |
        {more, binary()} |
        {more, header(), binary()} |
        {error, stream_id(), error_code(), binary()}.
recv(Bin) when is_binary(Bin), byte_size(Bin) < 9 ->
    {more, Bin};
recv(Bin) when is_binary(Bin) ->
    {InitFrame, RestBin} = recv_header(Bin),
    recv({InitFrame, RestBin});
recv({#{length := Length}, Bin}) when size(Bin) < Length ->
    {more, Frame, Bin};
recv({#{type = Type} = Frame, Bin}) ->
    recv(Type, Frame, Bin).


render(#{} = Frame) ->
    render([Frame]);

render(Frames) when is_list(Frames) ->
    lists:map(fun(Frame) ->
        #{
            type := Type,
            flags := Flags,
            stream_id := StreamId,
            data := Data
        } = Frame,
        IoData = render(Type, Frame),
        Length = erlang:iolist_size(IoData),
        Header = <<
            Length:24,
            h2_convert:to_code(Type):8,
            flags_to_code(Flags):8,
            0:1,
            StreamId:31
        >>,
        [Header, IoData].
    end, Frames).


new(Type) ->
    new(Type, 0, 0).


new(Type, StreamId) ->
    new(Type, StreamId, 0).


new(Type, StreamId, Flags) ->
    % Roundtrip flags so that all flag keys
    % are defined.
    AllFlags = flags_from_code(flags_to_code(Flags)),
    #{
        type => Type,
        length => 0,
        flags => AllFlags,
        stream_id => StreamId,
        data => undefined,
        priority => undefined,
        promised_stream_id => undefined
    }.


rst_stream(StreamId, ErrorCode) ->
    Base = new(rst_stream, StreamId),
    Base#{
        data = ErrorCode
    }.


settings_ack() ->
    Base = new(settings, 0, #{ack => true}),
    Base#{
        data := []
    }.


ping_ack(Data) ->
    Base = new(ping, 0, #{ack := true}),
    Base#{
        data := Data
    }.


goaway(LastStreamId, ErrorCode) ->
    Base = new(goaway, 0),
    Base#{
        data := {LastStreamId, ErrorCode, <<>>}
    }.


window_update(StreamId, Length) ->
    Base = new(window_update, StreamId),
    Base#{
        data := Length
    }.


set_flags(Frame, #{} = Flags) ->
    #{
        flags := CurrFlags
    } = Frame,
    maps:fold(fun(FlagName, Value, Acc) ->
        try
            h2_convert:to_code(flag, FlagName)
        catch error:badmatch ->
            erlang:error({invalid_flag, FlagName})
        end,
        Acc#{FlagName := Value}
    end, CurrFlags, Flags).


-spec recv_header(binary()) -> {frame(), binary()}.
recv_header(Bin) ->
    <<
        Length:24,
        Type:8,
        Flags:8,
        _R:1,
        StreamId:31,
        Rest/binary
    >> = Bin,
    Frame = #{
        type => h2_convert:from_code(frame_type, Type),
        length => Length,
        flags => flags_from_code(Flags),
        stream_id => StreamId,
        data => undefined,
        priority => undefined,
        promised_stream_id => undefined
    },
    {Frame, Rest}.


-spec recv(frame_type(), frame(), binary()) ->
        {ok, frame(), binary()} |
        {error, stream_id(), non_neg_integer(), binary()}.
recv(data, #{stream_id := 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv(data, #{length := 0} = Frame, _Bin) ->
    {ok, Frame#{data := <<>>}, Bin};
recv(data, Frame, Bin) ->
    #{
        length := Length,
        stream_id := StreamId
    } = Frame,
    <<MaybePadded:Length/binary, Rest/binary>> = Bin,
    case depad(Frame, MaybePadded) of
        {ok, Data} ->
            {ok, Frame#{data := Data}, Rest}
        {error, Code} ->
            {error, StreamId, Code, Rest}
    end;

recv(headers, #{stream_id := 0}, _) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv(headers; Frame, Bin) ->
    #{
        length := Length,
        flags := Flags,
        stream_id := StreamId
    } = Frame,
    <<MaybePadded:Length/binary, Rest/binary>> = Bin,
    case depad(Frame, MaybePadded) of
        {ok, Data} ->
            {Priority, RestData} = case maps:get(priority, Flags) of
                true ->
                    read_priority(Data)
                false ->
                    {undefiend, Data}
            end,
            {ok, Frame#{data := RestData, priority := Priority}, Rest};
        {error, Code} ->
            {error, StreamId, Code, Rest}
    end;

recv(priority, #{stream_id := 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv(priority, #{length := Length}, Bin) when Length /= 5 ->
    <<_:Length/binary, Rest/binary>> = Bin,
    #{
        stream_id = StreamId
    } = Frame,
    {error, StreamId, ?FRAME_SIZE_ERROR, Rest};
recv(priority, Frame, Bin) ->
    #{
        stream_id := StreamId
    } = Frame,
    {Priority, Rest} = h2_priority:read(Bin),
    {ok, Frame#{priority := Priority}, Rest};

recv(rst_stream, #{stream_id := 0}, _Bin) ->
    {error, 0, ?PROTOCOL_ERROR, <<>>};
recv(rst_stream, #{length := Length}, _Bin) when Length /= 4 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv(rst_stream, Frame, Bin) ->
    <<ErrorCode:32, Rest/binary>> = Bin,
    {ok, Frame#{data := ErrorCode}, Rest};

recv(settings, #{length := Length}, _Bin) when Length rem 6 /= 0 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv(settings, #{stream_id := 0, length := 0} = Frame, Bin) ->
    {ok, Frame#{data := h2_settings:new()}, Bin};
recv(settings, #{stream_id := 0} = Frame, Bin) ->
    #{
        length = Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    Settings = parse_settings(Data, []),
    {ok, Frame#{data := Settings}, Rest};
recv(settings, Frame, Bin) ->
    #{
        stream_id := StreamId
    } = Frame,
    % Invalid stream_id for settings frame
    {error, StreamId, ?PROTOCOL_ERROR, Bin}.

recv(push_promise, #{stream_id := 0}, Bin) ->
    {error, 0, ?PROTOCOL_ERROR, Bin};
recv(push_promise, Frame, Bin) ->
    #{
        length := Length,
        stream_id := StreamId
    } = Frame,
    <<MaybePadded:Length/binary, Rest/binary>> = Bin,
    case depad(Frame, MaybePadded) of
        {ok, Data} ->
            <<_R:1, PromisedStreamId:31, RestData/binary>> = Data,
            NewFrame = Frame#{
                promised_stream_id := PromisedStreamId,
                data := RestData
            },
            {ok, NewFrame, Rest};
        {error, Code} ->
            {error, StreamId, Code, Rest}
    end;

recv(ping, #{stream_id := 0, length := 8}, Bin) ->
    <<Data:8/binary, Rest/binary>> = Bin,
    {ok, Frame#{data := Data}, Rest};
recv(ping, #{stream_id := 0}, Bin} ->
    % Invalid length for ping frame
    {error, 0, ?FRAME_SIZE_ERROR, Bin};
recv(ping, Frame, Bin) ->
    #{
        stream_id := StreamId
    } = Frame,
    % Invalid stream_id for ping
    {error, StreamId, ?PROTOCOL_ERROR, Bin};

recv(goaway, #{stream_id := 0} = Frame, Bin) ->
    #{
        length := Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    <<_R:1, LastStreamId:31, ErrorCode:32, Extra/binary>> = Data,
    {ok, Frame#{data = {LastStreamId, ErrorCode, Debug}}, Rest};
recv(goaway, Frame, Bin) ->
    #{
        stream_id := StreamId
    } = Frame,
    % Invalid stream_id for goaway
    {error, StreamId, ?PROTOCOL_ERROR, Bin};

recv(window_update, #{length := Length}, _Bin) when Length /= 4 ->
    {error, 0, ?FRAME_SIZE_ERROR, <<>>};
recv(window_update, Frame, <<_R:1, 0:31, Rest/binary>>) ->
    #{
        stream_id := StreamId
    } = Frame,
    {error, StreamId, ?PROTOCOL_ERROR, Rest};
recv(window_update, Frame, Bin) ->
    <<_R:1, Increment:31, Rest/binary>> = Bin,
    {ok, Frame#{data = Increment}, Rest};

recv(continuation, #{stream_id := 0}, Bin) ->
    {error, 0, ?PROTOCOL_ERROR, Bin};
recv(continuation, Frame, Bin) ->
    #{
        length := Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    {ok, Frame#{data := Data}, Rest};

recv(_Unknown, Frame, Bin) ->
    #{
        length := Length
    } = Frame,
    <<Data:Length/binary, Rest/binary>> = Bin,
    {ok, Frame#{data := Data}, Rest}.


render(data, #{data := Data}) when is_binary(Data) ->
    Data;

render(headers, #{data := Data} = Frame) when is_binary(Data) ->
    #{
        flags := Flags,
        priority := Priority,
    } = Frame,
    case maps:get(priority, Flags) of
        true ->
            [render_priority(Priority), Data];
        false ->
            Data
    end;

render(priority, #{priority := Priority}) ->
    render_priority(Priority);

render(rst_stram, #{data := ErrCode}) when is_integer(ErrCode), ErrCode >= 0 ->
    <<ErrCode:32>>;

render(settings, #{data := Settings}) when is_list(Settings) ->
    lists:map(fun({Key, Value}) ->
        KeyCode = h2_convert:to_code(settings_key, Key),
        <<KeyCode:16, Value:32/big-unsigned-integer>>
    end, Settings);

render(push_promise, #{data := {StreamId, Data})
        when is_integer(StreamId), StreamId > 0, is_binary(Data) ->
    <<0:1, StreamId:31, Data/binary>>;

render(ping, #{data := Data}) when is_binary(Data), size(Data) == 8 ->
    Data;

render(goaway, #{data := {LastStreamId, ErrorCode, Debug}}) ->
        when is_integer(LastStreamId), LastStreamId > 0,
            is_integer(ErrorCode), ErrorCode > 0,
            is_binary(Data) ->
    <<0:1, LastStreamId:31, ErrorCode:32, Debug/binary>>;

render(window_update, #{data := Increment})
        when is_integer(Increment), Increment > 0 ->
    <<0:1, Increment:31>>;

render(continuation, #{data := Data}) when is_binary(Data) ->
    Data;

render(_Unknown, #{data := Data}) when is_binary(Data) ->
    Data.


parse_settings(<<>>, Acc) ->
    lists:reverse(Acc);

parse_settings(Bin, Acc) ->
    <<Key:16, Value:4/binary, Rest/binary>> = Bin,
    case h2_convert:from_code(settings_key, Key) of
        unknown ->
            % RFC 7541 Section 6.5.2: An endpoint that
            % receives a SETTINGS frame with any unknown
            % or unsupported identifier MUST ignore
            % that setting.
            parse_settings(Rest, Acc);
        SettingsKey ->
            [{SettingsKey, binary:decode_unsigned(Value)}]
    end.


flags_from_code(Flags) ->
    AllFlags = [?ACK, ?END_STREAM, ?END_HEADERS, ?PADDED, ?PRIORITY],
    lists:foldl(fun(FlagKey, Acc) ->
        FlagName = h2_convert:from_code(flag, FlagKey),
        Present = (FlagKey band Flags) == FlagKey of
        Acc#{FlagName => IsPresent}
    end, #{}, AllFlags).


flags_to_code(Flags) ->
    maps:fold(fun(FlagName, Value, Acc) ->
        if not Value -> Acc; true ->
           Flag = h2_convert:to_code(flag, FlagName),
           Acc bor Flag
        end
    end, 0, Flags).

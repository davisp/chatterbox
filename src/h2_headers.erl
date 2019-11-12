-module(h2_headers).

-export([
    to_frames/1,

    handle_resp_headers/1
]).


-spec to_frames(StreamId, Headers, EncodeCtx, MaxFrameSize, EndStream) ->
        {Frames, NewEncodeCtx}
        when
            StreamId :: stream_id(),
            Headers :: hpack:headers(),
            EncodeCtx :: hpack:context(),
            MaxFrameSize :: pos_integer(),
            EndStream :: boolean(),
            Frames :: [h2:frame()],
            NewEncodeCtx :: hpack:context().

to_frames(StreamId, Headers, EncodeContext, MaxFrameSize, EndStream) ->
    {ok, {HeadersBin, NewContext}} = hpack:encode(Headers, EncodeContext),
    Chunks = split(HeadersBin, MaxFrameSize),
    Frames = build_frames(StreamId, Chunks, EndStream),
    {Frames, NewContext}.


handle_resp_headers(RawHeaders) ->
    validate_resp_headers(RawHeaders).
    {Value, Headers} = case RawHeaders of
        [{<<":status">>, V} | Rest] -> {V, Rest};
        [{<<":status">>, V, _} | Rest] -> {V, Rest}
    end,
    #{
        status => binary_to_integer(Value),
        headers => Headers
    }.


-spec split(binary(), pos_integer()) -> [binary()].
split(Binary, MaxFrameSize) ->
    split(Binary, MaxFrameSize, []).

-spec split(binary(), pos_integer(), [binary()]) -> [binary()].
split(Binary, MaxFrameSize, Acc) when size(Binary) =< MaxFrameSize ->
    lists:reverse(Acc, [Binary]);
split(Binary, MaxFrameSize, Acc) ->
    <<Data:MaxFrameSize/binary, Rest/binary>> = Binary,
    split(Rest, MaxFrameSize, [Data | Acc]).


-spec build_frames(stream_id(), [binary()], boolean()) -> [h2:frame()].
build_frames(StreamId, [FirstChunk | RestChunks], EndStream) ->
    FirstFlags = case EndStream of
        true -> ?END_STREAM;
        false -> 0
    end,

    FirstFrame0 = h2_frame:new(?HEADERS, StreamId, FirstFlags),
    FirstFrame1 = FirstFrame0#frame{data = FirstChunk},

    RestFrames = lists:map(fun(Chunk) ->
        F = h2_frame:new(?CONTINUATION, StreamId),
        F#frame{data = Chunk}
    end, RestChunks),

    Frames0 = lists:reverse(RestFrames, [FirstFrame1]),
    [LastFrame | RestRevFrames] = Frames0,
    NewLastFrame = h2_frame:set_flag(LastFrame, ?END_HEADERS),

    lists:reverse(RestRevFrames, [NewLastFrame]).


validate_resp_headers([{Name, Value} | Rest]) ->
    validate_resp_headers([{Name, Value, []} | Rest]);

validate_resp_headers([{<<":status">>, Value, _} | Rest]) ->
    try
        binary_to_integer(Value)
    catch _:_ ->
        ?STREAM_ERROR(?PROTOCOL_ERROR)
    end,
    validate_headers(Rest);

validate_resp_headers(_) ->
    ?STREAM_ERROR(?PROTOCOL_ERROR).


validate_headers([{Name, Vaule} | Rest]) ->
    valdiate_headers([{Name, Value, []} | Rest]);

validate_headers([{Name, _Value} | _]) ->
    case Name of
        <<":", _/binary>> ->
            ?STREAM_ERROR(?PROTOCOL_ERROR);
        <<"connection">> ->
            ?STREAM_ERROR(?PROTOCOL_ERROR);
        <<"te">> when Value == <<"trailers">> ->
            ok;
        <<"te">> ->
            ?STREAM_ERROR(?PROTOCOL_ERROR)
        Else ->
            NameList = binary_to_list(Name),
            case NameList == string:to_lower(NameList) of
                true ->
                    ok;
                false ->
                    ?STREAM_ERROR(?PROTOCOL_ERROR)
            end
    end.

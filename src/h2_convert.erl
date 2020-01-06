-module(h2_humanize).


-export([
    from_code/2,
    to_code/2
]).



from_code(frame_type, Type) ->
    case Type of
        ?DATA -> data,
        ?HEADERS -> headeres,
        ?PRIORITY -> priority,
        ?RST_STREAM -> rst_stream,
        ?SETTINGS -> settings,
        ?PUSH_PROMISE -> push_promise,
        ?PING -> ping,
        ?GOAWAY -> goaway,
        ?WINDOW_UPDATE -> window_update,
        ?CONTINUATION -> continuation
        Unknown -> Unknown
    end;

from_code(flags, Flag) ->
    case Flag of
        ?ACK -> ack;
        ?END_STREAM -> end_stream;
        ?END_HEADERS -> end_headers;
        ?PADDED -> padded;
        ?PRIORITY -> priority
    end;

from_code(settings_key, Key) ->
    case Key of
        ?HEADER_TABLE_SIZE -> header_table_size;
        ?ENABLE_PUSH -> enable_push;
        ?MAX_CONCURRENT_STREAMS -> max_concurrent_streams;
        ?INITIAL_WINDOW_SIZE -> initial_window_size;
        ?MAX_FRAME_SIZE -> max_frame_size;
        ?MAX_HEADER_LIST_SIZE -> max_header_list_size;
        _Unknown -> unknown
    end.


to_code(frame_type, Type) ->
    case Type of
        data -> ?DATA;
        headers -> ?HEADERS;
        priority -> ?PRIORITY;
        rst_stream -> ?RST_STREAM;
        settings -> ?SETTINGS;
        push_promise -> ?PUSH_PROMISE;
        ping -> ?PING;
        goaway -> ?GOAWAY;
        window_update -> ?WINDOW_UPDATE;
        continuation -> ?CONTINUATION;
        Unknown when is_integer(Unknown) -> Unknown
    end;

to_code(flags, Flag) ->
    case Flag of
        ack -> ?ACK;
        end_stream -> ?END_STREAM;
        end_headers -> ?END_HEADERS;
        padded -> ?PADDED;
        priority -> ?PRIORITY
    end;

to_code(settings_key, Key) ->
    case Key of
        header_table_size -> ?HEADER_TABLE_SIZE;
        enable_push -> ?ENABLE_PUSH;
        max_concurrent_streams -> ?MAX_CONCURRENT_STREAMS;
        initial_window_size -> ?INITIAL_WINDOW_SIZE;
        max_frame_size -> ?MAX_FRAME_SIZE;
        max_header_list_size -> ?MAX_HEADER_LIST_SIZE
    end.
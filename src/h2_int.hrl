%% This file is part of Chatterbox released
%% under the MIT License.


% Frame types
-define(DATA,           16#0).
-define(HEADERS,        16#1).
-define(PRIORITY,       16#2).
-define(RST_STREAM,     16#3).
-define(SETTINGS,       16#4).
-define(PUSH_PROMISE,   16#5).
-define(PING,           16#6).
-define(GOAWAY,         16#7).
-define(WINDOW_UPDATE,  16#8).
-define(CONTINUATION,   16#9).


% Error codes
-define(NO_ERROR,           16#0).
-define(PROTOCOL_ERROR,     16#1).
-define(INTERNAL_ERROR,     16#2).
-define(FLOW_CONTROL_ERROR, 16#3).
-define(SETTINGS_TIMEOUT,   16#4).
-define(STREAM_CLOSED,      16#5).
-define(FRAME_SIZE_ERROR,   16#6).
-define(REFUSED_STREAM,     16#7).
-define(CANCEL,             16#8).
-define(COMPRESSION_ERROR,  16#9).
-define(CONNECT_ERROR,      16#a).
-define(ENHANCE_YOUR_CALM,  16#b).
-define(INADEQUATE_SECURITY,16#c).
-define(HTTP_1_1_REQUIRED,  16#d).


-type error_code() ::
    ?NO_ERROR |
    ?PROTOCOL_ERROR |
    ?INTERNAL_ERROR |
    ?FLOW_CONTROL_ERROR |
    ?SETTINGS_TIMEOUT |
    ?STREAM_CLOSED |
    ?FRAME_SIZE_ERROR |
    ?REFUSED_STREAM |
    ?CANCEL |
    ?COMPRESSION_ERROR |
    ?CONNECT_ERROR |
    ?ENHANCE_YOUR_CALM |
    ?INADEQUATE_SECURITY |
    ?HTTP_1_1_REQUIRED.


% Flags
-define(ACK,            16#1).
-define(END_STREAM,     16#1).
-define(END_HEADERS,    16#4).
-define(PADDED,         16#8).
-define(PRIORITY,       16#20).

-type flag() ::
    ?ACK |
    ?END_STREAM |
    ?END_HEADERS |
    ?PADDED |
    ?PRIORITY.

-define(IS_FLAG(Flags, Flag), Flags band Flag =:= Flag).
-define(NOT_FLAG(Flags, Flag), Flags band Flag =/= Flag).


% Settings
-define(HEADER_TABLE_SIZE,          16#1).
-define(ENABLE_PUSH,                16#2).
-define(MAX_CONCURRENT_STREAMS,     16#3).
-define(INITIAL_WINDOW_SIZE,        16#4).
-define(MAX_FRAME_SIZE,             16#5).
-define(MAX_HEADER_LIST_SIZE,       16#6).

-define(KNOWN_SETTINGS, [
    ?HEADER_TABLE_SIZE,
    ?ENABLE_PUSH,
    ?MAX_CONCURRENT_STREAMS,
    ?INITIAL_WINDOW_SIZE,
    ?MAX_FRAME_SIZE,
    ?MAX_HEADER_LIST_SIZE
]).


-define(PREFACE, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").


-define(DEFAULT_INITIAL_WINDOW_SIZE, 65535).


-type frame_type() ::
    ?DATA |
    ?HEADERS |
    ?PRIORITY |
    ?RST_STREAM |
    ?SETTINGS |
    ?PUSH_PROMISE |
    ?PING |
    ?GOAWAY |
    ?WINDOW_UPDATE |
    ?CONTINUATION |
    integer(). % Unknown frame types


-type flags() :: #{
    ack := boolean(),
    end_stream := boolean(),
    end_headers := boolean(),
    padded := boolean(),
    priority := boolean()
}.


-type priority() :: #{
    exclusive := boolean(),
    dependency := h2:stream_id(),
    weight := 1..256
}.


-type frame() :: #{
    type := frame_type(),
    length := non_neg_integer(),
    flags := flags(),
    stream_id := h2:stream_id(),
    data := term(),
    priority := priority() | undefined,
    promised_stream_id := h2:stream_id() | undefined
}.


-type stream_state() ::
    idle |
    open |
    closed |
    reserved_local |
    reserved_remote |
    half_closed_local |
    half_closed_remote.

% Not to be confused with the public facing `stream()`
% from h2.erl
-type stream() :: #{
    stream_id := h2:stream_id(),
    direction := send | recv,
    control_pid := pid() | undefined,
    state := stream_state(),
    ended := boolean(),
    priority := h2_frame:priority() | undefined,

    send_window_size := integer(),
    recv_window_size := integer(),

    send_queue := queue:queue(binary() | h2:headers()),
    send_queue_size := non_neg_integer()
}.


-type stream_set() :: #{
    active_count := non_neg_integer(),
    max_stream_id := stream_id(),
    streams := #{stream_id() => stream()}.
}.


-type machine() :: #{
    type := client | server,
    state := handshake | connected | continuation | closed,

    acceptor := h2:stream_acceptor() | undefined,

    send_settings := h2:settings(),
    recv_settings := h2:settings(),
    recv_settings_queue := queue:queue(h2:settings()),

    send_window_size := integer(),
    recv_window_size := integer(),

    encode_context := hpack:context(),
    decode_context := hpack:context(),

    next_stream_id := h2:stream_id(),
    max_peer_stream_id := h2:stream_id(),

    send_streams := streams(),
    recv_streams := streams(),

    pings := #{binary() => pid()},
    header_acc := [h2_frame:frame()]
}).


-define(ERROR(Value), throw({?MODULE, Value})).
-define(RETURN(Frames), ?ERROR({return, Frames})).
-define(CONN_ERROR(Error), ?ERROR({goaway, Error})).
-define(STRM_ERROR(StreamId, Error), ?ERROR({rst_stream, StreamId, Error})).

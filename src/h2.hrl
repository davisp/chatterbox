
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


% Type declarations

-type stream_id() :: non_neg_integer().


-record(priority, {
    exclusive = 0 :: 0 | 1,
    stream_id = 0 :: stream_id(),
    weight = 0 :: non_neg_integer()
}).

-type priority() :: #priority{}.


-record(settings, {
    header_table_size        = 4096,
    enable_push              = 1,
    max_concurrent_streams   = unlimited,
    initial_window_size      = 65535,
    max_frame_size           = 16384,
    max_header_list_size     = unlimited
}).

-type settings() :: #settings{}.


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
    integer(). % Unsupported frame types


-type frame_data() ::
    undefined | % Unread frame
    binary() | % data, continuation, ping
    {stream_id(), error_code(), binary()} | % goaway
    {priority(), binary()} | % headers
    priority() | % priority
    {stream_id(), binary()} | % push_promise
    error_code() | % rst_stream
    settings() | % settings
    non_neg_integer(). % window_update


-record(frame, {
    length :: non_neg_integer() | undefined,
    type :: frame_type() | undefined,
    flags = 0 :: non_neg_integer(),
    stream_id :: stream_id(),
    data :: frame_data()
}).

-type frame() :: #frame{}.


-define(PREFACE, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n").


-define(DEFAULT_INITIAL_WINDOW_SIZE, 65535).


-type stream_state() ::
    idle |
    reserved_local |
    reserved_remote |
    open |
    half_closed_local |
    half_closed_remote |
    closed.


-type stream() :: #{
    id := stream_id(),
    pid := pid()
}.


-type stream_int() :: #{
    id := stream_id(),
    state := stream_state(),
    type := client | server,
    controlling_pid := pid(),
    handler := fun(term(), term(), term()) -> term(),
    send_queue := queue:queue(),
    send_window_size := integer(),
    recv_window_size := integer(),
    resp := undefined | complete | async | response(),
    error := undefined | error_code()
}.


-type stream_group() :: #{
    streams := streams(),
    oldest_id := non_neg_integer(),
    next_id := non_neg_integer(),
    active := non_neg_integer()
}.


-record(stream_set, {
    type = client :: client | server,

    send_settings :: settings(),
    recv_settings :: settings(),

    recv_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),
    send_window_size = ?DEFAULT_INITIAL_WINDOW_SIZE :: integer(),

    local = stream_group(),
    remote = stream_group()
}).


-type stream_set() :: #stream_set{}.


-type header_opt() :: no_index | never_index | no_name_index | uncompressed.
-type header() :: {binary(), binary()} | {binary(), binary(), [header_opt()]}.
-type headers() [header()].


-type stream_opt() :: async.
-type send_opt() :: end_stream.


-type response() :: #{
    staus := non_neg_integer(),
    headers := headers(),
    body => iodata(),
    trailers => headers()
}.


-define(CONN_ERROR(ErrorCode), throw({h2_goaway, ErrorCode})).
-define(
    STREAM_ERROR(StreamId, ErrorCode),
    throw({h2_stream_error, StreamId, ErrorCode})
).


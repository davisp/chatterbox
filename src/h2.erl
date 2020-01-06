%% This file is part of Chatterbox released
%% under the MIT License.

-module(h2).

-type stream_id() :: non_neg_integer().
-type status_code() :: non_neg_integer().
-type http2_error() :: non_neg_integer().


-type header_opt() :: no_index | never_index | no_name_index | uncompressed.
-type header() :: {binary(), binary()} | {binary(), binary(), header_opt()}.
-type headers() :: [header()].

-type body() :: iodata() | empty | stream. % empty is equivalent to `<<>>`

-type promise_action() :: accept | decline | fun(headers()) -> boolean().
-type request_opt() :: stream | {promises, promise_action()}.

-type response() :: #{
    status := status_code(),
    headers := headers(),
    body => iodata(),
    trailers => headers(),
    promises => [response()]
}.


-type recv_opt() :: {timeout, non_neg_integer() | infinity}.

-type recv_msg() ::
    {headers, status_code(), headers()} |
    {promise, PromiseStreamId, PromiseHeaders} |
    {body, iodata()} |
    {trailers, headers()} |
    closed |
    {error, http2_error()}.

-type bare_recv_message() :: {stream_id(), recv_msg()}.


-type send_opt() :: end_stream | {trailers, headers()}.

-type send_msg() ::
    response() |
    iodata() |
    {iodata(), end_stream} |
    #{trailers := Trailers}.


-type conn() :: pid().

-type conn_settings() :: #{
    header_table_size => non_neg_integer(),
    enable_push => boolean(),
    max_concurrent_streams => non_neg_integer(),
    initial_window_size => non_neg_integer(),
    max_frame_size => non_neg_integer(),
    max_header_list_size => non_neg_integer()
}.


-type connect_opts() :: [conn_settings()].


-type stream() :: #{
    stream_id := stream_id(),
    conn := pid()
}.


-type promise() :: #{
    stream_id := stream_id(),
    conn := conn()
}.


-type stream_acceptor() :: {Mod :: atom(), Fun :: atom(), Arg :: term()}.


-export_type([
    stream_id/0,
    status_code/0,
    http2_error/0,

    header_opt/0,
    header/0,
    headers/0,
    body/0,

    promise_action/0,
    request_opt/0,

    response/0,

    recv_opt/0,
    recv_msg/0,
    bare_recv_msg/0,

    send_opt/0,
    send_msg/0,

    conn/0,
    conn_settings/0,
    connect_opts/0,

    stream/0,
    promise/0,

    stream_acceptor/0
]).


-export([
    connect/1,
    connect/2,

    serve/3,
    serve/4,

    request/3,
    request/4,

    recv/1,
    recv/2,
    send/1,
    send/2,

    accept/1,
    accept/2,
    reject/1,

    promise/2,
    promise/3,

    stream_id/1
]).


%% @equiv connect(URI, []).
-spec connect(http_uri:uri()) -> {ok, conn()} | {error, Term}.
connect(URI) ->
    h2_connection:start_link(URI, []).


%% @doc Create an HTTP/2 connection to the given
%% URI. Note that only the scheme, host, and port
%% are used from the URI. Specifically, any provided
%% `user_info`, `path`, `query_string`, and `fragment`
%% values are discarded.
-spec connect(http_uri:uri(), connect_opts()) -> {ok, conn()} | {error, Term}.
connect(URI, Options) ->
    h2_connection:start_link(URI, Options).


%% @equiv serve(Transport, Socket, Acceptor, []).
-spec serve(atom(), term(), stream_acceptor()) -> no_return().
serve(Transport, Socket, Acceptor) ->
    h2_connection:serve({Transport, Socket}, Acceptor, []).


%% @doc Transform the current process into an HTTP/2 serving
%% process using the provided transport, socket, and stream
%% acceptor.
%%
%% Currently, Transport must be either `gen_tcp` or `ssl`
%% with the corresponding correct socket type.
%%
%% The stream accceptor is a `{Module, Function, Arg}` triple
%% that is used to handle client initated streams. When a
%% client sends headers on a new stream, this function is invoked
%% as `Module:Function(Stream, RequestHeaders, Arg)`. The return
%% value of this function should be `{ok, pid()}` where
%% the `pid()` is unlinked and unmonitored. The server
%% process will take its own monitor to clean up any streams
%% when a handler exits. Alternatively, the acceptor can
%% return `cancel` which case the stream is forcefully terminated
%% or alternatively a complete `response()` which will
%% then be forwarded to the client (useful for 404 or
%% similar quick responses).
-spec serve(atom(), term(), stream_acceptor(), connect_opts()) -> no_return().
serve(Transport, Socket, Acceptor, Options) ->
    h2_connection:serve({Transport, Socket}, Acceptor, Options).


%% @equiv request(Conn, Headers, Body, []).
-spec request(conn(), headers(), body()) ->
        {ok, response()} | {ok, stream()} | {error, Term}.
request(Conn, Headers, Body) ->
    h2_connection:request(Conn, Headers, Body, []).


%% @doc Start a new client stream on the given connection.
%% If body is `stream` then the client is responsible for
%% issuing the appropriate `h2:send/1,2` calls to complete
%% the request. It is not forbidden to interleave calls
%% to `h2:recv/1,2` while sending data. Though any protocol
%% coordination with the server using this pattern is outside
%% the scope of HTTP/2.
-spec request(conn(), headers(), body(), [request_opt()] | request_opt()) ->
        {ok, response()} | {ok, stream()} | {error, Term}.
request(Conn, Headers, Body, Options) ->
    h2_connection:request(Conn, Headers, Body, Options).


%% @equiv recv(Stream, []).
-spec recv(stream()) -> recv_msg().
recv(Stream) ->
    h2_stream:recv(Stream, []).


%% @doc Receive the next message from the stream. Currently
%% the HTTP/2 spec constrains the possible ordering
%% of non-error messages to:
%%
%%  1. Exactly one headers message
%%  2. Zero or more data messages
%%  3. Zero or one trailers message
%%  4. Exactly one closed message
%%
%% In a few instances the headers message is elided as it
%% is provided in the API. For instance, when starting a
%% new stream on a server in response to a client request.
%%
%% Any error message received immediately halts the
%% message protocol and closes the stream. Its important
%% to note that these are protocol errors which is not
%% the same thing as an HTTP 500 or similar.
-spec recv(stream(), [recv_opt()]) -> recv_msg().
recv(Stream, Options) ->
    h2_stream:recv(Stream, Options).


%% @equiv send(Stream, Msg, []).
-spec send(stream(), send_msg()) -> ok | {error, Term}.
send(Stream, Msg) ->
    h2_stream:send(Stream, Msg, []).


%% @doc Send the given message on the stream. Clients must
%% follow the general HTTP/2 protocol. Failure to do so
%% will result in an error exception. For client streams
%% this means that only the `iodata()` and `trailers`
%% messages are valid to be sent.
%%
%% Server streams must send some form of the response
%% followed optionally by `iodata()` and then `trailers`
%% messages.
%%
%% A stream is closed for sending as soon as the first
%% stream ending condition is met. Thus, it is an error
%% to send `trailers` after `{iodata(), end_stream}`.
%% For a server, if the initial response includes either
%% the `body` or `trailers` member the stream is closed
%% immediately and no more send calls are valid.
-spec send(stream(), send_msg(), send_opt()) -> ok.
send(Stream, Msg, Options) ->
    h2_stream:send(Stream, Msg, Options).


%% @equiv accept/2
-spec accept(promise()) -> {ok, stream()} | {error, Term}.
accept(Promise) ->
    h2_connection:accept(Promise, []).


%% @doc Accept the given promise. If the `stream` option
%% is provided, the Erlang process that calls `accept`
%% becomes the controlling process of the stream. It is
%% valid and common to have a different process call
%% `accept` than the process which received the promise.
-spec accept(promise(), [request_opt()] | request_opt()) ->
        {ok, response()} | {ok, stream()} | {error, Term}.
accept(Promise, Options) ->
    h2_connection:accept(Promise, Options).


%% @doc Reject the given promise. All data for the promised
%% stream is discarded.
-spec reject(promise()) -> ok.
reject(Promise) ->
    h2_connection:reject(Promise).


%% @doc Create the given promise using the specified
%% request headers. This call is only valid from an
%% HTTP/2 server process.
%%
%% Also note that the `stream_acceptor()` will be invoked
%% with the provided request headers when creating the
%% underlying promised stream.
-spec promise(stream(), headers()) -> ok.
promise(Stream, Headers) ->
    h2_connection:promise(Stream, Headers).


%% @doc Create the given promise using the specified
%% request headers. This call is only valid from an
%% HTTP/2 server process.
%%
%% Similar to `promise/2` except that the provided
%% `stream_acceptor()` will be used instead of the
%% connection's acceptor.
-spec promise(stream(), headers(), stream_acceptor()) -> ok.
promise(Stream, Headers, Acceptor) ->
    h2_connection:promise(Stream, Headers, Acceptor).


%% @doc Retrieve the underlying `stream_id()` from
%% a `stream()` or `promise()`.
-spec stream_id(stream() | promise()) -> stream_id().
stream_id(#{stream_id := StreamId}) ->
    StreamId.

%% This file is part of Chatterbox released
%% under the MIT License.

% Some API usage examples

% Creating connections:

{ok, Conn} = h2:connect("http://127.0.0.1:50051"),
{ok, Conn} = h2:connect("https://my-http2-test", [some, options, here]).

% Basic HTTP/2 Client API

simple_request(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    {ok, Resp} = h2:request(Conn, Headers, empty),
    #{
        status := 200,
        headers := headers(),
        body := iodata(),
        trailers := headers()
    } = Resp.
​
​
send_req_body(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>},
        {<<"content-length">>, <<"3">>}
    ],
    Body = <<"foo">>
    {ok, Resp} = h2:request(Conn, Headers, Body),
    #{
        status := 200,
        headers := headers(),
        body := iodata(),
        trailers := headers()
    } = Resp.
​
​
stream_response(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    {ok, Stream} = h2:request(Conn, Headers, empty, stream),

    {headers, Status, Headers} = h2:recv(Stream),

    Loop = fun Loop(Acc) ->
        case h2:recv(Stream) of
            {data, Data} ->
                Loop([Data | Acc]);
            {trailers, Trailers}
                Loop({Acc, Trailers});
            closed ->
                {lists:reverse([Data | Acc]), []};
            {error, ErrCode} ->
                erlang:error({http2_error, Stream, ErrCode})
        end
    end,
    {Body, Trailers} = Loop([]).
    ​
​
stream_req_body(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    {ok, Stream} = h2:request(Conn, Headers, stream),
​
    lists:foreach(fun(_) ->
        h2:send(Stream, <<"foo">>)
    end, lists:seq(1, 10)),
​
    % Either of these
    h2:send(Stream, {<<"last data">>, end_stream}),
    h2:send(Stream, #{trailers => Trailers}),
​
    {ok, Resp} = h2:recv(Stream),
    #{
        status := 200,
        headers := headers(),
        body := iodata(),
        trailers => headers()
    } = Resp.
​
​
bidirectional_streaming(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    {ok, Stream} = h2:request(Conn, Headers, stream, stream),

    % Complete lack of error handling here
    % is due to just illustrating the API.

    ok = h2:send(Stream, <<"do some stuff">>),
    {headers, Status, Headers} = h2:recv(Stream),

    ok = h2:send(Stream, <<"do more stuff">>),
    {data, Data} = h2:recv(Stream),

    ok = h2:send(Stream, {<<"done with stream">>, end_stream}),
    closed = h2:recv(Stream).

​
default_promise_behavior(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    % Default behavior
    {ok, Resp} = h2:request(Conn, Headers, empty, [{promises, decline}]),
    #{
        status := 200,
        headers := headers(),
        body := iodata(),
        trailers := headers()
    } = Resp.
​
​
accept_promises(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    {ok, Resp} = h2:request(Conn, Headers, empty, [{promises, accept}]),
    #{
        status := 200,
        headers := headers(),
        body := iodata(),
        trailers := headers(),
        promises := [response()]
    } = Resp.


stream_promises(Conn) ->
    Headers = [
        {<<":scheme">>, <<"http">>},
        {<<":method">>, <<"GET">>},
        {<<":path">>, <<"/">>}
    ]
    {ok, Stream} = h2:request(Conn, Headers, empty, stream),

    Streams = #{
        h2:stream_id(Stream) => {Stream, #{body => []}}
    },
​
    loop(Streams, 1).
​

loop(Streams, 0) ->
    {ok, Streams};
loop(Streams, Active) when Active > 0 ->
    receive
        {StreamId, {headers, Status, Headers}} ->
            {Stream, Resp} = maps:get(StreamId, Streams),
            NewResp = Resp#{status => Status, headers => Headers},
            loop(Streams#{StreamId => NewResp}, Active);
        {StreamId, {data, Data}} ->
            {Stream, #{body := Body} = Resp} = maps:get(StreamId, Streams),
            NewResp = Resp#{body := [Data | Body]},
            loop(Streams#{StreamId := NewResp}, Active);
        {StreamId, {trailers, Trailers}} ->
            {Stream, #{body := Body} = Resp} = maps:get(StreamId, Streams),
            NewResp = Resp#{body := lists:reverse(Body), trailers => Trailers},
            loop(Streams#{StreamId := NewResp}, Active - 1);
        {StreamId, {promise, Promise, PromiseHeaders}} ->
            % PromiseHeaders are what *would* have been sent if
            % the client had initiated this request. You can use
            % these to decide whether to accept or reject this
            % promise.

            % Read the whole promise at once
            % {ok, PromiseResp} = h2:accept(Promise)
            %
            % Cancel the promise
            % ok = h2:cancel(Promise)

            % You could also spawn a process here to handle the promise
            % if that makes sense. However, the thing to note is that
            % the process that calls `h2:accept/1,2` is the process that
            % gets the messages.
            {ok, PromiseStream} = h2:accept(Promise, [stream]),
            PromiseStreamId = h2:stream_id(Promise),
            NewStreams = Streams#{
                PromiseStreamId => {PromiseStream, #{body => []}}
            },
            loop(NewStreams, Active + 1)
        {StreamId, closed} ->
            loop(Streams, Active - 1)
    end.

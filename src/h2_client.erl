-module(h2_client).
-include("h2.hrl").

%% Today's the day! We need to turn this gen_server into a gen_statem
%% which means this is going to look a lot like the "opposite of
%% http2_connection". This is the way to take advantage of the
%% abstraction of http2_socket. Still, the client API is way more
%% important than the server API so we're going to have to work
%% backwards from that API to get it right

%% {request, Headers, Data}
%% {request, [Frames]}
%% A frame that is too big should know how to break itself up.
%% That might mean into Continutations

%% API
-export([
         start_link/2,
         start_link/4,
         stop/1,
         send_request/3,
         send_ping/1,
         sync_request/3,
         get_response/2
        ]).


-spec start_link(string(), [ssl:ssl_option()]) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start_link(URI, SSLOptions) ->
    case http_uri:parse(URI) of
        {ok, {Scheme, _, Host, Port, _, _} ->
            start_link(Scheme, Host, Port, SSLOptions);
        {ok, {Scheme, _, Host, Port, _, _, _}} ->
            start_link(Scheme, Host, Port, SSLOptions);
        _ ->
            {error, {invalid_uri, URI}}
    end.


%% Here's your all access client starter. MAXIMUM TUNABLES! Scheme,
%% Hostname, Port and SSLOptions. All of the start_link/* calls come
%% through here eventually, so this is where we turn 'http' and
%% 'https' into 'gen_tcp' and 'ssl' for erlang module function calls
%% later.
-spec start_link(http | https,
                 string(),
                 non_neg_integer(),
                 [ssl:ssl_option()]) ->
                        {ok, pid()}
                      | ignore
                      | {error, term()}.
start_link(http, Host, Port, SSLOptions) ->
    Settings = h2_settings:new(),
    h2_connection:start_client_link(gen_tcp, Host, Port, SSLOptions, Settings);
start_link(https, Host, Port, SSLOptions) ->
    Settings = h2_settings:new(),
    h2_connection:start_client_link(ssl, Host, Port, SSLOptions, Settings);
start_link(Transport, _, _, _) ->
    {error, {invalid_transport, Transport}}.


-spec stop(pid()) -> ok.
stop(Pid) ->
    h2_connection:stop(Pid).

-spec sync_request(CliPid, Headers, Body) -> Result when
      CliPid :: pid(), Headers :: hpack:headers(), Body :: binary(),
      Result :: {ok, {hpack:headers(), iodata()}}
                 | {error, error_code() | timeout}.
sync_request(CliPid, Headers, Body) ->
    case send_request(CliPid, Headers, Body) of
        {ok, StreamId} ->
            receive
                {'END_STREAM', StreamId} ->
                    h2_connection:get_response(CliPid, StreamId)
            after 5000 ->
                      {error, timeout}
            end;
        Error ->
            Error
    end.

-spec send_request(CliPid, Headers, Body) -> Result when
      CliPid :: pid(), Headers :: hpack:headers(), Body :: binary(),
      Result :: {ok, stream_id()} | {error, error_code()}.
send_request(CliPid, Headers, Body) ->
    case h2_connection:new_stream(CliPid) of
        {error, _Code} = Err ->
            Err;
        StreamId ->
            h2_connection:send_headers(CliPid, StreamId, Headers),
            h2_connection:send_body(CliPid, StreamId, Body),
            {ok, StreamId}
    end.

send_ping(CliPid) ->
    h2_connection:send_ping(CliPid).

-spec get_response(pid(), stream_id()) ->
                          {ok, {hpack:header(), iodata()}}
                           | not_ready
                           | {error, term()}.
get_response(CliPid, StreamId) ->
    h2_connection:get_response(CliPid, StreamId).

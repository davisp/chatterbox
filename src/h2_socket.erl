-module(h2_socket).

-type transport() :: gen_tcp | ssl.
-type socket() ::
    {gen_tcp, inet:socket() | undefined} |
    {ssl, ssl:sslsocket() | undefined}.

-export_type([
    transport/0,
    socket/0
]).

-export([
    send/2,
    recv/2,
    recv/3,
    close/1,

    peername/1,
    peercert/1,
    setopts/2
]).


send({gen_tcp, Socket}, Data) ->
    gen_tcp:send(Socket, Data);
send({ssl, Socket}, Data) ->
    ssl:send(Socket, Data);
send(Socket, _) ->
    erlang:error({bad_socket, Socket}).


recv(Socket, Length) ->
    recv(Socket, Length, infinity).


recv({gen_tcp, Socket}, Length, Timeout) ->
    gen_tcp:recv(Socket, Length, Timeout);
recv({ssl, Socket}, Length, Timeout) ->
    ssl:recv(Socket, Length, Timeout);
recv(Socket, _, _) ->
    erlang:error({bad_socket, Socket}).


close({Transport, Socket}) ->
    Transport:close(Socket).


peername({ssl, Socket}) ->
    ssl:peername(Socket);
peername({gen_tcp, Socket}) ->
    inet:peername(Socket).


peercert({ssl, Socket}) ->
    ssl:peercert(Socket);
peercert({gen_tcp, _Socket}) ->
    erlang:error(unsupported).


setopts({ssl, Socket}, Opts) ->
    ssl:setopts(Socket, Opts);
setopts({gen_tcp, Socket}, Opts) ->
    inet:setopts(Socket, Opts).

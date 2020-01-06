-module(h2_conn).
-behavior(gen_server).


-export([
    connect/1,
    connect/2,

    request/3,
    request/4
]).


-export([
    init/1,
    terminate/2,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3
]).


connect(URI) ->
    gen_server:start_link(?MODULE, {URI, []}, []).


connect(URI, Options) ->
    gen_server:start_link(?MODULE, {URI, Options}, []).


init({URI, Options}) ->
    {ok, #{}}.


terminate(_Reason, _St) ->
    ok.


handle_call(Msg, _From, St) ->
    {stop, {bad_call, Msg}, {bad_call, Msg}, St}.


handle_cast(Msg, St) ->
    {stop, {bad_cast, Msg}, St}.


handle_info(Msg, St) ->
    {stop, {bad_info, Msg}, St}.


code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

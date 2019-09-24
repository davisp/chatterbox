-module(h2_settings).
-include("http2.hrl").

-export([
         new/0,
         validate/1,
         merge/2,
         diff/2,
         to_proplist/1
        ]).


-spec new() -> settings().
new() ->
    #settings{}.


-spec validate([proplists:property()]) -> ok | {error, integer()}.
validate([]) ->
    ok;
validate([{?ENABLE_PUSH, Push} | _]) when Push > 1; Push < 0 ->
    {error, ?PROTOCOL_ERROR};
validate([{?INITIAL_WINDOW_SIZE, Size} | _]) when Size >=2147483648 ->
    {error, ?FLOW_CONTROL_ERROR};
validate([{?MAX_FRAME_SIZE, Size} | _]) when Size < 16384; Size > 16777215 ->
    {error, ?PROTOCOL_ERROR};
validate([_ | Rest]) ->
    validate(Rest).


-spec merge(settings(), [{non_neg_integer(), non_neg_integer()}]) -> settings().
merge(Settings, []) ->
    Settings;
merge(Settings, [{?HEADER_TABLE_SIZE, Value} | Rest]) ->
    merge(Settings#settings{header_table_size = Value}, Rest);
merge(Settings, [{?ENABLE_PUSH, Value} | Rest]) ->
    merge(Settings#settings{enable_push = Value}, Rest);
merge(Settings, [{?MAX_CONCURRENT_STREAMS, Value} | Rest]) ->
    merge(Settings#settings{max_concurrent_streams = Value}, Rest);
merge(Settings, [{?INITIAL_WINDOW_SIZE, Value} | Rest]) ->
    merge(Settings#settings{initial_window_size = Value}, Rest);
merge(Settings, [{?MAX_FRAME_SIZE, Value} | Rest]) ->
    merge(Settings#settings{max_frame_size = Value}, Rest);
merge(Settings, [{?MAX_HEADER_LIST_SIZE, Value} | Rest]) ->
    merge(Settings#settings{max_header_list_size = Value}, Rest).


-spec diff(settings(), settings()) -> settings_proplist().
diff(OldSettings, NewSettings) ->
    OldPl = to_proplist(OldSettings),
    NewPl = to_proplist(NewSettings),
    diff_(OldPl, NewPl, []).

diff_([],[],Acc) ->
    lists:reverse(Acc);
diff_([OldH|OldT],[OldH|NewT],Acc) ->
    diff_(OldT, NewT, Acc);
diff_([_OldH|OldT],[NewH|NewT],Acc) ->
    diff_(OldT, NewT, [NewH|Acc]).


-spec to_proplist(settings()) -> settings_proplist().
to_proplist(Settings) ->
    [
     {?SETTINGS_HEADER_TABLE_SIZE,      Settings#settings.header_table_size     },
     {?SETTINGS_ENABLE_PUSH,            Settings#settings.enable_push           },
     {?SETTINGS_MAX_CONCURRENT_STREAMS, Settings#settings.max_concurrent_streams},
     {?SETTINGS_INITIAL_WINDOW_SIZE,    Settings#settings.initial_window_size   },
     {?SETTINGS_MAX_FRAME_SIZE,         Settings#settings.max_frame_size        },
     {?SETTINGS_MAX_HEADER_LIST_SIZE,   Settings#settings.max_header_list_size  }
    ].

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

diff_test() ->
    Old = #settings{},
    New = #settings{
             max_frame_size=2048
            },
    Diff = diff(Old, New),
    ?assertEqual([{?SETTINGS_MAX_FRAME_SIZE, 2048}], Diff),
    ok.

diff_order_test() ->
    Old = #settings{},
    New = #settings{
             max_frame_size = 2048,
             max_concurrent_streams = 2
            },
    Diff = diff(Old, New),
    ?assertEqual(
       [{?SETTINGS_MAX_CONCURRENT_STREAMS, 2},
        {?SETTINGS_MAX_FRAME_SIZE, 2048}],
       Diff
      ),
    ?assertNotEqual(
       [
        {?SETTINGS_MAX_FRAME_SIZE, 2048},
        {?SETTINGS_MAX_CONCURRENT_STREAMS, 2}
       ],
       Diff
      ),

    ok.

-endif.

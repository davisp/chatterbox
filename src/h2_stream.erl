-module(h2_stream).


%% RFC 7540 Section 5.1 - Stream States
%%
%%                          +--------+
%%                  send PP |        | recv PP
%%                 ,--------|  idle  |--------.
%%                /         |        |         \
%%               v          +--------+          v
%%        +----------+          |           +----------+
%%        |          |          | send H /  |          |
%% ,------| reserved |          | recv H    | reserved |------.
%% |      | (local)  |          |           | (remote) |      |
%% |      +----------+          v           +----------+      |
%% |          |             +--------+             |          |
%% |          |     recv ES |        | send ES     |          |
%% |   send H |     ,-------|  open  |-------.     | recv H   |
%% |          |    /        |        |        \    |          |
%% |          v   v         +--------+         v   v          |
%% |      +----------+          |           +----------+      |
%% |      |   half   |          |           |   half   |      |
%% |      |  closed  |          | send R /  |  closed  |      |
%% |      | (remote) |          | recv R    | (local)  |      |
%% |      +----------+          |           +----------+      |
%% |           |                |                 |           |
%% |           | send ES /      |       recv ES / |           |
%% |           | send R /       v        send R / |           |
%% |           | recv R     +--------+   recv R   |           |
%% | send R /  `----------->|        |<-----------'  send R / |
%% | recv R                 | closed |               recv R   |
%% `----------------------->|        |<----------------------'
%%                          +--------+
%%
%%    send:   endpoint sends this frame
%%    recv:   endpoint receives this frame
%%
%%    H:  HEADERS frame (with implied CONTINUATIONs)
%%    PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
%%    ES: END_STREAM flag
%%    R:  RST_STREAM frame


-include("h2.hrl").


-export([
    new/2,

    headers/3,
    data/3,
    priority/3,
    reset/3,
    window_update/3,

    has_queued_data/1,
    prepare_frames/3
]).


-spec new(stream_id(), idle | closed) -> stream().
new(StreamId, State, Direction, SWSize, RWSize) ->
    #{
        stream_id => StreamId,
        control_id => undefined,
        state => State,
        direction => Direction,
        ended = false,
        priority => undefined,

        send_window_size => SWSize,
        recv_window_size => RWSize,

        send_queue => queue:new(),
        send_queue_size => 0
    }.


-spec headers(machine(), stream(), frame()) -> stream().
headers(Stream, Frame) ->
    #{
        state := State,
        direction := Direction
    } = Stream,
    #{
        data := Headers,
        flags := #{end_stream := EndStream}
    } = Frame,

    case {State, Direction, EndStream} of
        {idle, recv, _} ->
            % New stream, transitioning to
            ok;
        {idle, send, false}

-spec data(machine(), stream(), frame()) -> stream().
data(_Machine, _Kind, Stream, Frame) ->
    #{
        control_pid := ControlPid,
        recv_window_size := RecvWindowSize
    } = Stream,
    #{
        type := data,
        data := Data
    } = Frame,

    case size(Data) > RecvWindowSize of
        true ->
            ?STREAM_ERROR()


-spec priority(machine(), stream(), frame()) -> stream().
priority(_Machine, _Kind, Stream, Frame) ->
    #{
        type := priority,
        data := Priority
    } = Frame,
    maps:put(priority, Priority, Stream).


-spec reset(machine(), stream(), frame()) -> stream().
reset(Machine, Stream, Frame) ->
    ok.


-spec window_update(machine(), stream(), frame()) -> stream().
window_udpate(Machine, Stream, Frame) ->
    ok.


-spec has_queued_data(stream()) -> boolean().
has_queued_data(Stream) ->
    #{
        send_queue_size := SQS
    } = Stream,
    SQS > 0.


-spec prepare_frames(machine(), stream(), non_neg_integer()) ->
        {stream(), non_neg_integer(), [frame()]}.
prepare_frames(Machine, Stream, SendWindowSize) ->
    ok.

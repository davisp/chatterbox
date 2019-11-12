-module(h2).


-include("h2.hrl").


-export_type([
    error_code/0,
    flag/0,

    stream_id/0,

    priority/0,
    settings/0,

    frame_type/0,
    frame_data/0,
    frame/0,

    stream_type/0,
    stream_state/0,
    stream/0,

    header_opt/0,
    header/0,
    headers/0
]).

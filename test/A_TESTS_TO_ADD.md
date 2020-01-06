
Settings Processing
===

* Handle settings after connection handshake

* Set the max header table size twice to a small and then larger
  value to ensure we shrink and grow properly.

    % RFC 7540 Section 6.5.3
    % The values in the SETTINGS frame MUST be processed
    % in the order they appear, with no other frame
    % processing between values.


Headers Processing
===

* Support for SETTINGS_MAX_HEADER_LIST_SIZE
* What happens when we get a headers frame on an open stream without end_stream set?
* Mismatched stream ids in continuation blocks
* Mismatched stream id in last continuation block


Stream States
===

* Can a PUSH_PROMISE send an empty response with end_stream=true on initial headers?
* Sending on END_STREAM flagged stream vs RST_STREAM frame (connection error vs stream error).
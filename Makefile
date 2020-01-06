# This file is part of Chatterbox released
# under the MIT License.

all:
    rebar3 do compile, eunit, ct, dialyzer


clean:
    rebar3 clean
	rm -rf _build

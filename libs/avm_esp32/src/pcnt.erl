%
% This file is part of AtomVM.
%
% Copyright 2026 Dennis Palmer <dodava@gmail.com>
%
% Licensed under the Apache License, Version 2.0 (the "License");
% you may not use this file except in compliance with the License.
% You may obtain a copy of the License at
%
%    http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
% See the License for the specific language governing permissions and
% limitations under the License.
%
% SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
%

%%-----------------------------------------------------------------------------
%% @doc Pulse counter (PCNT) low-level APIs
%%
%% The functions in this module broadly reflect the ESP-IDF
%% <a href="https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/pcnt.html">Pulse Counter</a>
%% driver. A PCNT unit counts edges in hardware, so it keeps up with signals
%% far faster than GPIO interrupts can, such as a motor's quadrature encoder.
%%
%% A unit has one or more channels. Each channel watches an edge GPIO and,
%% optionally, a level GPIO that can invert or hold the count. A unit is
%% configured, then enabled, then started:
%%
%% ```
%% {ok, Unit} = pcnt:new_unit(#{low_limit => -1000, high_limit => 1000}),
%% ok = pcnt:new_channel(Unit, #{edge_gpio => 4, pos_edge => increase}),
%% ok = pcnt:enable(Unit),
%% ok = pcnt:start(Unit),
%% {ok, Count} = pcnt:get_count(Unit).
%% '''
%%
%% For a quadrature (A/B) encoder, such as the Hall encoder on a DC gear
%% motor, {@link new_encoder/3} does all of this.
%%
%% The hardware unit is freed when the unit term is garbage collected, or
%% right away with {@link del_unit/1}.
%%
%% PCNT is available on the ESP32, ESP32-S2, ESP32-S3, ESP32-C5, ESP32-C6,
%% ESP32-H2 and ESP32-P4, but not on the ESP32-C2 or ESP32-C3.
%% @end
%%-----------------------------------------------------------------------------
-module(pcnt).

% The NIFs are called as ?MODULE:Fun(...), because AtomVM only resolves a
% platform NIF on a remote call.
-export([
    new_unit/1,
    new_channel/2,
    set_glitch_filter/2,
    enable/1,
    disable/1,
    start/1,
    stop/1,
    get_count/1,
    clear_count/1,
    del_unit/1,
    new_encoder/3
]).

-type unit() :: reference().
%% A PCNT unit, as returned by `new_unit/1'.

-type gpio_num() :: non_neg_integer().

-type unit_option() ::
    {low_limit, -32768..-1}
    | {high_limit, 1..32767}
    | {accum_count, boolean()}.
%% `low_limit' and `high_limit' (default `-32768' and `32767') are where the
%% hardware counter wraps back to 0. With `{accum_count, true}' the driver adds
%% each wrap to a software total, so `get_count/1' keeps counting past the
%% limits instead of wrapping.

-type unit_config() :: [unit_option()] | #{atom() => term()}.

-type edge_action() :: hold | increase | decrease.
-type level_action() :: keep | inverse | hold.

-type channel_option() ::
    {edge_gpio, gpio_num() | undefined}
    | {level_gpio, gpio_num() | undefined}
    | {pos_edge, edge_action()}
    | {neg_edge, edge_action()}
    | {high_level, level_action()}
    | {low_level, level_action()}
    | {invert_edge_input, boolean()}
    | {invert_level_input, boolean()}.
%% `pos_edge' and `neg_edge' (default `increase' and `hold') say what a rising
%% or falling edge on `edge_gpio' does to the count. `high_level' and
%% `low_level' (default `keep') say how the `level_gpio' level changes that:
%% `keep' it, `inverse' it (`increase' becomes `decrease' and the other way
%% round) or `hold' the count. The driver enables the internal pull-up on
%% both pins.

-type channel_config() :: [channel_option()] | #{atom() => term()}.

-type encoder_option() ::
    {glitch_filter_ns, non_neg_integer()}
    | {accum_count, boolean()}
    | {low_limit, -32768..-1}
    | {high_limit, 1..32767}.
%% `glitch_filter_ns' (default `1000') ignores pulses shorter than that,
%% `0' turns the filter off. `accum_count' defaults to `true' here.

-type error_reason() :: no_free_unit | no_free_channel | atom() | integer().

-export_type([unit/0, unit_config/0, channel_config/0]).

%%-----------------------------------------------------------------------------
%% @param   Config unit configuration, as a proplist or a map
%% @returns `{ok, Unit}' or `{error, Reason}'
%% @doc     Allocate a PCNT unit.
%%
%% Returns `{error, no_free_unit}' when all the chip's units are in use.
%% @end
%%-----------------------------------------------------------------------------
-spec new_unit(Config :: unit_config()) -> {ok, unit()} | {error, error_reason()}.
new_unit(_Config) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @param   Config channel configuration, as a proplist or a map
%% @returns `ok' or `{error, Reason}'
%% @doc     Add a channel to a unit.
%%
%% Call this before `enable/1'. A unit has 2 channels on all current chips;
%% `{error, no_free_channel}' means they are both in use.
%%
%% A GPIO set as an output with `gpio:set_pin_mode/2' before this call stays
%% an output, and the channel counts what is written to it.
%% @end
%%-----------------------------------------------------------------------------
-spec new_channel(Unit :: unit(), Config :: channel_config()) -> ok | {error, error_reason()}.
new_channel(_Unit, _Config) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @param   MaxGlitchNs pulses shorter than this are ignored, `0' turns the
%%          filter off
%% @returns `ok' or `{error, Reason}'
%% @doc     Set the unit's glitch filter.
%%
%% Call this before `enable/1'. The longest filter depends on the APB clock,
%% about 12 µs at 80 MHz.
%% @end
%%-----------------------------------------------------------------------------
-spec set_glitch_filter(Unit :: unit(), MaxGlitchNs :: non_neg_integer()) ->
    ok | {error, error_reason()}.
set_glitch_filter(_Unit, _MaxGlitchNs) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `ok' or `{error, Reason}'
%% @doc     Enable the unit, after its channels and glitch filter are set.
%% @end
%%-----------------------------------------------------------------------------
-spec enable(Unit :: unit()) -> ok | {error, error_reason()}.
enable(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `ok' or `{error, Reason}'
%% @doc     Disable an enabled unit. Stop it first.
%% @end
%%-----------------------------------------------------------------------------
-spec disable(Unit :: unit()) -> ok | {error, error_reason()}.
disable(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `ok' or `{error, Reason}'
%% @doc     Start counting. The unit must be enabled.
%% @end
%%-----------------------------------------------------------------------------
-spec start(Unit :: unit()) -> ok | {error, error_reason()}.
start(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `ok' or `{error, Reason}'
%% @doc     Stop counting. The count is kept.
%% @end
%%-----------------------------------------------------------------------------
-spec stop(Unit :: unit()) -> ok | {error, error_reason()}.
stop(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `{ok, Count}' or `{error, Reason}'
%% @doc     Read the count.
%% @end
%%-----------------------------------------------------------------------------
-spec get_count(Unit :: unit()) -> {ok, integer()} | {error, error_reason()}.
get_count(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `ok' or `{error, Reason}'
%% @doc     Set the count, including the `accum_count' total, back to 0.
%% @end
%%-----------------------------------------------------------------------------
-spec clear_count(Unit :: unit()) -> ok | {error, error_reason()}.
clear_count(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   Unit the PCNT unit
%% @returns `ok' or `{error, Reason}'
%% @doc     Stop and free the unit and its channels now.
%%
%% Without this, they are freed when `Unit' is garbage collected. Using
%% `Unit' afterwards raises `badarg'.
%% @end
%%-----------------------------------------------------------------------------
-spec del_unit(Unit :: unit()) -> ok | {error, error_reason()}.
del_unit(_Unit) ->
    erlang:nif_error(undefined).

%%-----------------------------------------------------------------------------
%% @param   PinA the encoder's A output
%% @param   PinB the encoder's B output
%% @param   Options encoder options, as a proplist or a map
%% @returns `{ok, Unit}' or `{error, Reason}'
%% @doc     Set up a started unit that counts a quadrature (A/B) encoder.
%%
%% It counts every edge on both A and B (4 counts per encoder cycle): up when
%% A leads B, down when B leads A. Swap the pins to flip the direction.
%% @end
%%-----------------------------------------------------------------------------
-spec new_encoder(
    PinA :: gpio_num(), PinB :: gpio_num(), Options :: [encoder_option()] | map()
) -> {ok, unit()} | {error, error_reason()}.
new_encoder(PinA, PinB, Options) when is_map(Options) ->
    new_encoder(PinA, PinB, maps:to_list(Options));
new_encoder(PinA, PinB, Options) when is_list(Options) ->
    UnitConfig = [
        {low_limit, proplists:get_value(low_limit, Options, -32768)},
        {high_limit, proplists:get_value(high_limit, Options, 32767)},
        {accum_count, proplists:get_value(accum_count, Options, true)}
    ],
    GlitchNs = proplists:get_value(glitch_filter_ns, Options, 1000),
    case ?MODULE:new_unit(UnitConfig) of
        {ok, Unit} ->
            Steps = [
                fun() ->
                    ?MODULE:new_channel(Unit, [
                        {edge_gpio, PinA},
                        {level_gpio, PinB},
                        {pos_edge, decrease},
                        {neg_edge, increase},
                        {high_level, keep},
                        {low_level, inverse}
                    ])
                end,
                fun() ->
                    ?MODULE:new_channel(Unit, [
                        {edge_gpio, PinB},
                        {level_gpio, PinA},
                        {pos_edge, increase},
                        {neg_edge, decrease},
                        {high_level, keep},
                        {low_level, inverse}
                    ])
                end,
                fun() -> ?MODULE:set_glitch_filter(Unit, GlitchNs) end,
                fun() -> ?MODULE:enable(Unit) end,
                fun() -> ?MODULE:clear_count(Unit) end,
                fun() -> ?MODULE:start(Unit) end
            ],
            case run_steps(Steps) of
                ok ->
                    {ok, Unit};
                Error ->
                    ?MODULE:del_unit(Unit),
                    Error
            end;
        Error ->
            Error
    end.

%% @private
run_steps([]) ->
    ok;
run_steps([Step | Rest]) ->
    case Step() of
        ok -> run_steps(Rest);
        Error -> Error
    end.

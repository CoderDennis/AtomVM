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

-module(test_pcnt).
-export([start/0]).

% The test drives these pins as outputs and counts what it writes, so they
% need no wiring. Leave them unconnected.
-define(PIN_A, 4).
-define(PIN_B, 5).

start() ->
    ok = gpio:set_pin_mode(?PIN_A, output),
    ok = gpio:set_pin_mode(?PIN_B, output),
    ok = set_ab(0, 0),
    ok = test_encoder(),
    ok = test_stop_start(),
    ok = test_limits_wrap(),
    ok = test_accum_count(),
    ok = test_single_channel_map_config(),
    ok = test_bad_args(),
    ok = test_del_unit(),
    ok = test_units_freed_on_gc(),
    ok.

test_encoder() ->
    {ok, Unit} = pcnt:new_encoder(?PIN_A, ?PIN_B, []),
    {ok, 0} = pcnt:get_count(Unit),
    ok = forward(10),
    {ok, 40} = pcnt:get_count(Unit),
    ok = backward(10),
    {ok, 0} = pcnt:get_count(Unit),
    ok = backward(3),
    {ok, -12} = pcnt:get_count(Unit),
    ok = pcnt:clear_count(Unit),
    {ok, 0} = pcnt:get_count(Unit),
    ok = pcnt:del_unit(Unit).

test_stop_start() ->
    {ok, Unit} = pcnt:new_encoder(?PIN_A, ?PIN_B, []),
    ok = forward(1),
    ok = pcnt:stop(Unit),
    ok = forward(5),
    {ok, 4} = pcnt:get_count(Unit),
    ok = pcnt:start(Unit),
    % a running unit can't be disabled
    {error, esp_err_invalid_state} = pcnt:disable(Unit),
    ok = forward(1),
    {ok, 8} = pcnt:get_count(Unit),
    ok = pcnt:del_unit(Unit).

% Without accum_count the hardware counter goes back to 0 when it reaches a
% limit.
test_limits_wrap() ->
    {ok, Unit} = pcnt:new_encoder(?PIN_A, ?PIN_B, [
        {low_limit, -10}, {high_limit, 10}, {accum_count, false}
    ]),
    ok = forward(3),
    {ok, 2} = pcnt:get_count(Unit),
    ok = pcnt:del_unit(Unit).

test_accum_count() ->
    {ok, Unit} = pcnt:new_encoder(?PIN_A, ?PIN_B, #{low_limit => -10, high_limit => 10}),
    ok = forward(25),
    {ok, 100} = pcnt:get_count(Unit),
    ok = backward(50),
    {ok, -100} = pcnt:get_count(Unit),
    ok = pcnt:clear_count(Unit),
    {ok, 0} = pcnt:get_count(Unit),
    ok = pcnt:del_unit(Unit).

% One channel, counting rising edges on A only, configured with a map.
test_single_channel_map_config() ->
    {ok, Unit} = pcnt:new_unit(#{low_limit => -100, high_limit => 100}),
    ok = pcnt:new_channel(Unit, #{edge_gpio => ?PIN_A, pos_edge => increase, neg_edge => hold}),
    ok = pcnt:set_glitch_filter(Unit, 0),
    ok = pcnt:enable(Unit),
    ok = pcnt:start(Unit),
    ok = forward(7),
    {ok, 7} = pcnt:get_count(Unit),
    % B is the level input of nothing here, so it changes nothing
    ok = gpio:digital_write(?PIN_B, high),
    ok = gpio:digital_write(?PIN_B, low),
    {ok, 7} = pcnt:get_count(Unit),
    ok = pcnt:stop(Unit),
    ok = pcnt:disable(Unit),
    ok = pcnt:del_unit(Unit).

test_bad_args() ->
    {error, esp_err_invalid_arg} = pcnt:new_unit([{low_limit, 5}]),
    {error, esp_err_invalid_arg} = pcnt:new_unit([{high_limit, 40000}]),
    ok = expect_badarg(fun() -> pcnt:new_unit(not_a_config) end),
    ok = expect_badarg(fun() -> pcnt:new_unit([{accum_count, 'maybe'}]) end),
    {ok, Unit} = pcnt:new_unit([]),
    ok = expect_badarg(fun() ->
        pcnt:new_channel(Unit, [{edge_gpio, ?PIN_A}, {pos_edge, sideways}])
    end),
    ok = expect_badarg(fun() -> pcnt:new_channel(Unit, [{edge_gpio, -1}]) end),
    ok = expect_badarg(fun() -> pcnt:get_count(make_ref()) end),
    ok = expect_badarg(fun() -> pcnt:get_count(not_a_unit) end),
    ok = pcnt:new_channel(Unit, [{edge_gpio, ?PIN_A}]),
    ok = pcnt:new_channel(Unit, [{edge_gpio, ?PIN_B}]),
    {error, no_free_channel} = pcnt:new_channel(Unit, [{edge_gpio, ?PIN_A}]),
    % starting a unit that isn't enabled
    {error, esp_err_invalid_state} = pcnt:start(Unit),
    ok = pcnt:del_unit(Unit).

test_del_unit() ->
    {ok, Unit} = pcnt:new_encoder(?PIN_A, ?PIN_B, []),
    ok = pcnt:del_unit(Unit),
    ok = expect_badarg(fun() -> pcnt:get_count(Unit) end),
    ok = expect_badarg(fun() -> pcnt:del_unit(Unit) end),
    % all units can be allocated, and freeing one makes room for another
    Units = alloc_all_units([]),
    true = length(Units) >= 1,
    [First | Rest] = Units,
    ok = pcnt:del_unit(First),
    {ok, Again} = pcnt:new_unit([]),
    ok = lists:foreach(fun(U) -> ok = pcnt:del_unit(U) end, [Again | Rest]).

% A process that dies holding units must not leak them.
test_units_freed_on_gc() ->
    Self = self(),
    {Pid, Ref} = spawn_opt(
        fun() ->
            Units = alloc_all_units([]),
            % started units, so the destructor has to stop and disable them
            lists:foreach(
                fun(U) ->
                    ok = pcnt:new_channel(U, [{edge_gpio, ?PIN_A}]),
                    ok = pcnt:enable(U),
                    ok = pcnt:start(U)
                end,
                Units
            ),
            Self ! {allocated, length(Units)}
        end,
        [monitor]
    ),
    N =
        receive
            {allocated, Count} -> Count
        after 5000 -> throw(timeout)
        end,
    receive
        {'DOWN', Ref, process, Pid, normal} -> ok
    after 5000 -> throw(timeout)
    end,
    Units = alloc_all_units([]),
    N = length(Units),
    ok = lists:foreach(fun(U) -> ok = pcnt:del_unit(U) end, Units).

alloc_all_units(Acc) ->
    case pcnt:new_unit([]) of
        {ok, Unit} -> alloc_all_units([Unit | Acc]);
        {error, no_free_unit} -> Acc
    end.

% One encoder cycle with A leading B: 4 counts up.
forward(0) ->
    ok;
forward(N) ->
    ok = set_ab(1, 0),
    ok = set_ab(1, 1),
    ok = set_ab(0, 1),
    ok = set_ab(0, 0),
    forward(N - 1).

% One encoder cycle with B leading A: 4 counts down.
backward(0) ->
    ok;
backward(N) ->
    ok = set_ab(0, 1),
    ok = set_ab(1, 1),
    ok = set_ab(1, 0),
    ok = set_ab(0, 0),
    backward(N - 1).

set_ab(A, B) ->
    ok = gpio:digital_write(?PIN_A, level(A)),
    ok = gpio:digital_write(?PIN_B, level(B)).

level(0) -> low;
level(1) -> high.

expect_badarg(Fun) ->
    try
        Fun(),
        should_fail
    catch
        error:badarg -> ok
    end.

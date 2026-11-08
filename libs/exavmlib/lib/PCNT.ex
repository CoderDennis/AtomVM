#
# This file is part of AtomVM.
#
# Copyright 2026 Dennis Palmer <dodava@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
#

defmodule PCNT do
  @compile {:no_warn_undefined, [:pcnt]}

  @moduledoc """
  Pulse counter (PCNT) low-level APIs.

  The functions in this module broadly reflect the ESP-IDF
  <a href="https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/pcnt.html">Pulse Counter</a>
  driver, and match the Erlang `:pcnt` module. Configurations can be keyword
  lists or maps.

      {:ok, unit} = PCNT.new_encoder(4, 5, glitch_filter_ns: 1000)
      {:ok, count} = PCNT.get_count(unit)

  PCNT is available on the ESP32, ESP32-S2, ESP32-S3, ESP32-C5, ESP32-C6,
  ESP32-H2 and ESP32-P4, but not on the ESP32-C2 or ESP32-C3.
  """

  @typedoc "A PCNT unit, as returned by `new_unit/1`."
  @type unit() :: reference()

  @type config() :: keyword() | map()

  @type error() :: {:error, atom() | integer()}

  @doc "Allocates a PCNT unit (`:low_limit`, `:high_limit`, `:accum_count`)."
  @spec new_unit(config()) :: {:ok, unit()} | error()
  def new_unit(_config), do: throw(:nif_error)

  @doc """
  Adds a channel to a unit (`:edge_gpio`, `:level_gpio`, `:pos_edge`,
  `:neg_edge`, `:high_level`, `:low_level`, `:invert_edge_input`,
  `:invert_level_input`).
  """
  @spec new_channel(unit(), config()) :: :ok | error()
  def new_channel(_unit, _config), do: throw(:nif_error)

  @doc "Ignores pulses shorter than `max_glitch_ns`; `0` turns the filter off."
  @spec set_glitch_filter(unit(), non_neg_integer()) :: :ok | error()
  def set_glitch_filter(_unit, _max_glitch_ns), do: throw(:nif_error)

  @doc "Enables the unit, after its channels and glitch filter are set."
  @spec enable(unit()) :: :ok | error()
  def enable(_unit), do: throw(:nif_error)

  @doc "Disables a stopped unit."
  @spec disable(unit()) :: :ok | error()
  def disable(_unit), do: throw(:nif_error)

  @doc "Starts counting."
  @spec start(unit()) :: :ok | error()
  def start(_unit), do: throw(:nif_error)

  @doc "Stops counting. The count is kept."
  @spec stop(unit()) :: :ok | error()
  def stop(_unit), do: throw(:nif_error)

  @doc "Reads the count."
  @spec get_count(unit()) :: {:ok, integer()} | error()
  def get_count(_unit), do: throw(:nif_error)

  @doc "Sets the count back to 0."
  @spec clear_count(unit()) :: :ok | error()
  def clear_count(_unit), do: throw(:nif_error)

  @doc "Stops and frees the unit now, instead of when it is garbage collected."
  @spec del_unit(unit()) :: :ok | error()
  def del_unit(_unit), do: throw(:nif_error)

  @doc """
  Sets up a started unit that counts a quadrature (A/B) encoder on `pin_a`
  and `pin_b`, 4 counts per encoder cycle. See `:pcnt.new_encoder/3`.
  """
  @spec new_encoder(non_neg_integer(), non_neg_integer(), config()) :: {:ok, unit()} | error()
  def new_encoder(pin_a, pin_b, options \\ []),
    do: :pcnt.new_encoder(pin_a, pin_b, options)
end

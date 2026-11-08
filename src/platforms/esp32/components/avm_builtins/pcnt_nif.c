/*
 * This file is part of AtomVM.
 *
 * Copyright 2026 Dennis Palmer <dodava@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0 OR LGPL-2.1-or-later
 */

// References
// https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/pcnt.html

#include <sdkconfig.h>
#include <soc/soc_caps.h>

#if defined(CONFIG_AVM_ENABLE_PCNT_NIFS) && SOC_PCNT_SUPPORTED

#include <string.h>

#include <driver/pulse_cnt.h>
#include <esp_log.h>

#include <context.h>
#include <defaultatoms.h>
#include <erl_nif_priv.h>
#include <globalcontext.h>
#include <interop.h>
#include <memory.h>
#include <nifs.h>
#include <term.h>

// #define ENABLE_TRACE
#include <trace.h>

#include "esp32_sys.h"

#define TAG "atomvm_pcnt"

static ErlNifResourceType *pcnt_unit_resource_type;

struct PCNTUnitResource
{
    pcnt_unit_handle_t unit;
    pcnt_channel_handle_t channels[SOC_PCNT_CHANNELS_PER_UNIT];
    bool enabled;
    bool started;
};

//
// internal functions
//

static term make_error_tuple(Context *ctx, term reason)
{
    if (UNLIKELY(memory_ensure_free_with_roots(ctx, TUPLE_SIZE(2), 1, &reason, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
        return OUT_OF_MEMORY_ATOM;
    }
    term ret = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(ret, 0, ERROR_ATOM);
    term_put_tuple_element(ret, 1, reason);
    return ret;
}

static term esp_error_tuple(Context *ctx, esp_err_t err)
{
    return make_error_tuple(ctx, esp_err_to_term(ctx->global, err));
}

// Returns NULL unless t is a live (not deleted) PCNT unit resource.
static struct PCNTUnitResource *get_unit(Context *ctx, term t)
{
    void *rsrc_obj_ptr;
    if (UNLIKELY(!enif_get_resource(erl_nif_env_from_context(ctx), t, pcnt_unit_resource_type, &rsrc_obj_ptr))) {
        return NULL;
    }
    struct PCNTUnitResource *rsrc_obj = (struct PCNTUnitResource *) rsrc_obj_ptr;
    if (IS_NULL_PTR(rsrc_obj->unit)) {
        return NULL;
    }
    return rsrc_obj;
}

// Stops, disables and deletes the unit and its channels, in the order the
// driver requires. Safe to call more than once.
static esp_err_t delete_unit(struct PCNTUnitResource *rsrc_obj)
{
    if (IS_NULL_PTR(rsrc_obj->unit)) {
        return ESP_OK;
    }
    esp_err_t err;
    if (rsrc_obj->started) {
        err = pcnt_unit_stop(rsrc_obj->unit);
        if (UNLIKELY(err != ESP_OK)) {
            return err;
        }
        rsrc_obj->started = false;
    }
    if (rsrc_obj->enabled) {
        err = pcnt_unit_disable(rsrc_obj->unit);
        if (UNLIKELY(err != ESP_OK)) {
            return err;
        }
        rsrc_obj->enabled = false;
    }
    for (int i = 0; i < SOC_PCNT_CHANNELS_PER_UNIT; i++) {
        if (rsrc_obj->channels[i] != NULL) {
            err = pcnt_del_channel(rsrc_obj->channels[i]);
            if (UNLIKELY(err != ESP_OK)) {
                return err;
            }
            rsrc_obj->channels[i] = NULL;
        }
    }
    err = pcnt_del_unit(rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        return err;
    }
    rsrc_obj->unit = NULL;
    return ESP_OK;
}

static bool term_is_list_or_map(term t)
{
    return term_is_list(t) || term_is_map(t);
}

static bool get_bool_opt(term opts, AtomString key, bool default_value, bool *ret, GlobalContext *glb)
{
    term value = interop_kv_get_value_default(opts, key, default_value ? TRUE_ATOM : FALSE_ATOM, glb);
    if (value == TRUE_ATOM) {
        *ret = true;
        return true;
    }
    if (value == FALSE_ATOM) {
        *ret = false;
        return true;
    }
    return false;
}

static bool get_int_opt(term opts, AtomString key, avm_int_t default_value, avm_int_t *ret, GlobalContext *glb)
{
    term value = interop_kv_get_value_default(opts, key, term_from_int(default_value), glb);
    if (!term_is_integer(value)) {
        return false;
    }
    *ret = term_to_int(value);
    return true;
}

// gpio option: a pin number, or `undefined` for no pin (-1)
static bool get_gpio_opt(term opts, AtomString key, int *ret, GlobalContext *glb)
{
    term value = interop_kv_get_value_default(opts, key, UNDEFINED_ATOM, glb);
    if (value == UNDEFINED_ATOM) {
        *ret = -1;
        return true;
    }
    if (!term_is_integer(value) || term_to_int(value) < 0) {
        return false;
    }
    *ret = term_to_int(value);
    return true;
}

static const AtomStringIntPair edge_action_table[] = {
    { ATOM_STR("\x4", "hold"), PCNT_CHANNEL_EDGE_ACTION_HOLD },
    { ATOM_STR("\x8", "increase"), PCNT_CHANNEL_EDGE_ACTION_INCREASE },
    { ATOM_STR("\x8", "decrease"), PCNT_CHANNEL_EDGE_ACTION_DECREASE },
    SELECT_INT_DEFAULT(-1)
};

static const AtomStringIntPair level_action_table[] = {
    { ATOM_STR("\x4", "keep"), PCNT_CHANNEL_LEVEL_ACTION_KEEP },
    { ATOM_STR("\x7", "inverse"), PCNT_CHANNEL_LEVEL_ACTION_INVERSE },
    { ATOM_STR("\x4", "hold"), PCNT_CHANNEL_LEVEL_ACTION_HOLD },
    SELECT_INT_DEFAULT(-1)
};

static bool get_action_opt(term opts, AtomString key, AtomString default_value, const AtomStringIntPair *table, int *ret, GlobalContext *glb)
{
    term value = interop_kv_get_value(opts, key, glb);
    if (term_is_invalid_term(value)) {
        value = globalcontext_make_atom(glb, default_value);
    }
    if (!term_is_atom(value)) {
        return false;
    }
    int action = interop_atom_term_select_int(table, value, glb);
    if (action < 0) {
        return false;
    }
    *ret = action;
    return true;
}

//
// Nif functions
//

// pcnt:new_unit(Opts) -> {ok, Unit} | {error, Reason}
static term nif_pcnt_new_unit(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    GlobalContext *glb = ctx->global;
    term opts = argv[0];
    VALIDATE_VALUE(opts, term_is_list_or_map);

    avm_int_t low_limit;
    avm_int_t high_limit;
    bool accum_count;
    if (UNLIKELY(!get_int_opt(opts, ATOM_STR("\x9", "low_limit"), INT16_MIN, &low_limit, glb)
            || !get_int_opt(opts, ATOM_STR("\xA", "high_limit"), INT16_MAX, &high_limit, glb)
            || !get_bool_opt(opts, ATOM_STR("\xB", "accum_count"), false, &accum_count, glb))) {
        RAISE_ERROR(BADARG_ATOM);
    }

    pcnt_unit_config_t config = {
        .low_limit = low_limit,
        .high_limit = high_limit,
        .flags.accum_count = accum_count
    };

    struct PCNTUnitResource *rsrc_obj = enif_alloc_resource(pcnt_unit_resource_type, sizeof(struct PCNTUnitResource));
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    memset(rsrc_obj, 0, sizeof(struct PCNTUnitResource));

    esp_err_t err = pcnt_new_unit(&config, &rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        rsrc_obj->unit = NULL;
        enif_release_resource(rsrc_obj);
        if (err == ESP_ERR_NOT_FOUND) {
            return make_error_tuple(ctx, globalcontext_make_atom(glb, ATOM_STR("\xC", "no_free_unit")));
        }
        return esp_error_tuple(ctx, err);
    }

    // The driver only adds the overflowed count to its accumulator when the
    // limits are watch points.
    if (accum_count) {
        err = pcnt_unit_add_watch_point(rsrc_obj->unit, high_limit);
        if (LIKELY(err == ESP_OK)) {
            err = pcnt_unit_add_watch_point(rsrc_obj->unit, low_limit);
        }
        if (UNLIKELY(err != ESP_OK)) {
            delete_unit(rsrc_obj);
            enif_release_resource(rsrc_obj);
            return esp_error_tuple(ctx, err);
        }
    }

    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2) + TERM_BOXED_RESOURCE_SIZE) != MEMORY_GC_OK)) {
        delete_unit(rsrc_obj);
        enif_release_resource(rsrc_obj);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term unit_term = term_from_resource(rsrc_obj, &ctx->heap);
    enif_release_resource(rsrc_obj);

    term ret = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(ret, 0, OK_ATOM);
    term_put_tuple_element(ret, 1, unit_term);
    return ret;
}

// pcnt:new_channel(Unit, Opts) -> ok | {error, Reason}
static term nif_pcnt_new_channel(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    GlobalContext *glb = ctx->global;
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    term opts = argv[1];
    VALIDATE_VALUE(opts, term_is_list_or_map);

    int edge_gpio;
    int level_gpio;
    int pos_edge;
    int neg_edge;
    int high_level;
    int low_level;
    bool invert_edge_input;
    bool invert_level_input;
    if (UNLIKELY(!get_gpio_opt(opts, ATOM_STR("\x9", "edge_gpio"), &edge_gpio, glb)
            || !get_gpio_opt(opts, ATOM_STR("\xA", "level_gpio"), &level_gpio, glb)
            || !get_action_opt(opts, ATOM_STR("\x8", "pos_edge"), ATOM_STR("\x8", "increase"), edge_action_table, &pos_edge, glb)
            || !get_action_opt(opts, ATOM_STR("\x8", "neg_edge"), ATOM_STR("\x4", "hold"), edge_action_table, &neg_edge, glb)
            || !get_action_opt(opts, ATOM_STR("\xA", "high_level"), ATOM_STR("\x4", "keep"), level_action_table, &high_level, glb)
            || !get_action_opt(opts, ATOM_STR("\x9", "low_level"), ATOM_STR("\x4", "keep"), level_action_table, &low_level, glb)
            || !get_bool_opt(opts, ATOM_STR("\x11", "invert_edge_input"), false, &invert_edge_input, glb)
            || !get_bool_opt(opts, ATOM_STR("\x12", "invert_level_input"), false, &invert_level_input, glb))) {
        RAISE_ERROR(BADARG_ATOM);
    }

    int slot = -1;
    for (int i = 0; i < SOC_PCNT_CHANNELS_PER_UNIT; i++) {
        if (rsrc_obj->channels[i] == NULL) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        return make_error_tuple(ctx, globalcontext_make_atom(glb, ATOM_STR("\xF", "no_free_channel")));
    }

    pcnt_chan_config_t config = {
        .edge_gpio_num = edge_gpio,
        .level_gpio_num = level_gpio,
        .flags.invert_edge_input = invert_edge_input,
        .flags.invert_level_input = invert_level_input
    };
    pcnt_channel_handle_t channel;
    esp_err_t err = pcnt_new_channel(rsrc_obj->unit, &config, &channel);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    err = pcnt_channel_set_edge_action(channel, pos_edge, neg_edge);
    if (LIKELY(err == ESP_OK)) {
        err = pcnt_channel_set_level_action(channel, high_level, low_level);
    }
    if (UNLIKELY(err != ESP_OK)) {
        pcnt_del_channel(channel);
        return esp_error_tuple(ctx, err);
    }
    rsrc_obj->channels[slot] = channel;

    return OK_ATOM;
}

// pcnt:set_glitch_filter(Unit, MaxGlitchNs) -> ok | {error, Reason}
static term nif_pcnt_set_glitch_filter(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    VALIDATE_VALUE(argv[1], term_is_integer);
    avm_int_t max_glitch_ns = term_to_int(argv[1]);
    if (UNLIKELY(max_glitch_ns < 0)) {
        RAISE_ERROR(BADARG_ATOM);
    }

    esp_err_t err;
    if (max_glitch_ns == 0) {
        // 0 turns the filter off
        err = pcnt_unit_set_glitch_filter(rsrc_obj->unit, NULL);
    } else {
        pcnt_glitch_filter_config_t config = {
            .max_glitch_ns = max_glitch_ns
        };
        err = pcnt_unit_set_glitch_filter(rsrc_obj->unit, &config);
    }
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    return OK_ATOM;
}

static term nif_pcnt_enable(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    esp_err_t err = pcnt_unit_enable(rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    rsrc_obj->enabled = true;
    return OK_ATOM;
}

static term nif_pcnt_disable(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    if (rsrc_obj->started) {
        // the driver refuses to disable a running unit
        return esp_error_tuple(ctx, ESP_ERR_INVALID_STATE);
    }
    esp_err_t err = pcnt_unit_disable(rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    rsrc_obj->enabled = false;
    return OK_ATOM;
}

static term nif_pcnt_start(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    esp_err_t err = pcnt_unit_start(rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    rsrc_obj->started = true;
    return OK_ATOM;
}

static term nif_pcnt_stop(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    esp_err_t err = pcnt_unit_stop(rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    rsrc_obj->started = false;
    return OK_ATOM;
}

// pcnt:get_count(Unit) -> {ok, Count} | {error, Reason}
static term nif_pcnt_get_count(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    int count;
    esp_err_t err = pcnt_unit_get_count(rsrc_obj->unit, &count);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    // with accum_count the count can exceed the unboxed integer range
    if (UNLIKELY(memory_ensure_free(ctx, TUPLE_SIZE(2) + term_boxed_integer_size(count)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term count_term = term_make_maybe_boxed_int64(count, &ctx->heap);
    term ret = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(ret, 0, OK_ATOM);
    term_put_tuple_element(ret, 1, count_term);
    return ret;
}

static term nif_pcnt_clear_count(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    esp_err_t err = pcnt_unit_clear_count(rsrc_obj->unit);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    return OK_ATOM;
}

// pcnt:del_unit(Unit) -> ok | {error, Reason}
// Frees the hardware unit now instead of waiting for the garbage collector.
static term nif_pcnt_del_unit(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct PCNTUnitResource *rsrc_obj = get_unit(ctx, argv[0]);
    if (IS_NULL_PTR(rsrc_obj)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    esp_err_t err = delete_unit(rsrc_obj);
    if (UNLIKELY(err != ESP_OK)) {
        return esp_error_tuple(ctx, err);
    }
    return OK_ATOM;
}

//
// entrypoints
//

static void pcnt_unit_resource_dtor(ErlNifEnv *caller_env, void *obj)
{
    UNUSED(caller_env);
    struct PCNTUnitResource *rsrc_obj = (struct PCNTUnitResource *) obj;
    esp_err_t err = delete_unit(rsrc_obj);
    if (UNLIKELY(err != ESP_OK)) {
        ESP_LOGW(TAG, "Failed to delete PCNT unit in resource d'tor. err=%i", err);
    }
}

static const ErlNifResourceTypeInit PCNTUnitResourceTypeInit = {
    .members = 1,
    .dtor = pcnt_unit_resource_dtor,
};

#define DEFINE_PCNT_NIF(name)                     \
    static const struct Nif pcnt_##name##_nif = { \
        .base.type = NIFFunctionType,             \
        .nif_ptr = nif_pcnt_##name                \
    };

DEFINE_PCNT_NIF(new_unit)
DEFINE_PCNT_NIF(new_channel)
DEFINE_PCNT_NIF(set_glitch_filter)
DEFINE_PCNT_NIF(enable)
DEFINE_PCNT_NIF(disable)
DEFINE_PCNT_NIF(start)
DEFINE_PCNT_NIF(stop)
DEFINE_PCNT_NIF(get_count)
DEFINE_PCNT_NIF(clear_count)
DEFINE_PCNT_NIF(del_unit)

static const struct
{
    const char *name;
    const struct Nif *nif;
} pcnt_nif_table[] = {
    { "new_unit/1", &pcnt_new_unit_nif },
    { "new_channel/2", &pcnt_new_channel_nif },
    { "set_glitch_filter/2", &pcnt_set_glitch_filter_nif },
    { "enable/1", &pcnt_enable_nif },
    { "disable/1", &pcnt_disable_nif },
    { "start/1", &pcnt_start_nif },
    { "stop/1", &pcnt_stop_nif },
    { "get_count/1", &pcnt_get_count_nif },
    { "clear_count/1", &pcnt_clear_count_nif },
    { "del_unit/1", &pcnt_del_unit_nif },
};

static void pcnt_nif_init(GlobalContext *global)
{
    ErlNifEnv env;
    erl_nif_env_partial_init_from_globalcontext(&env, global);
    pcnt_unit_resource_type = enif_init_resource_type(&env, "pcnt_unit", &PCNTUnitResourceTypeInit, ERL_NIF_RT_CREATE, NULL);
}

static const struct Nif *pcnt_nif_get_nif(const char *nifname)
{
    const char *function;
    if (strncmp("pcnt:", nifname, 5) == 0) {
        function = nifname + 5;
    } else if (strncmp("Elixir.PCNT:", nifname, 12) == 0) {
        function = nifname + 12;
    } else {
        return NULL;
    }
    for (size_t i = 0; i < sizeof(pcnt_nif_table) / sizeof(pcnt_nif_table[0]); i++) {
        if (strcmp(pcnt_nif_table[i].name, function) == 0) {
            TRACE("Resolved platform nif %s ...\n", nifname);
            return pcnt_nif_table[i].nif;
        }
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(pcnt, pcnt_nif_init, NULL, pcnt_nif_get_nif)

#endif

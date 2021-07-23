-- Copyright 2021 Kafka-Tarantool-Loader
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

---
--- Generated by EmmyLua(https://github.com/EmmyLua)
--- Created by ashitov.
--- DateTime: 6/26/20 6:14 PM
---
local role_name = 'app.roles.adg_state'
local metrics = require('app.metrics.metrics_storage')
local checks = require('checks')
local errors = require('errors')
local schema_utils = require('app.utils.schema_utils')
local misc_utils = require('app.utils.misc_utils')
local success_repository = require('app.messages.success_repository')
local error_repository = require('app.messages.error_repository')
local log = require('log')
local fun = require('fun')
local clock = require('clock')
local json = require('json')
local enums = require('app.entities.enum')
local cartridge = require('cartridge')
local prometheus = require('metrics.plugins.prometheus')
local global = require('app.utils.global').new('adg_state')
local fiber = require('fiber')
local yaml = require('yaml')
local math = require('math')

local cartridge_pool = require('cartridge.pool')
local cartridge_rpc = require('cartridge.rpc')

_G.update_delete_batch_storage = nil
_G.get_tables_from_delete_batch = nil
_G.remove_delete_batch = nil
_G.insert_kafka_callback_log = nil
_G.set_kafka_callback_log_result = nil
_G.insert_kafka_error_msg = nil
_G.insert_kafka_error_msgs = nil
_G.register_kafka_callback_function = nil
_G.get_callback_functions = nil
_G.get_callback_function_schema = nil
_G.delete_kafka_callback_function = nil
_G.delayed_delete_on_cluster = nil
_G.delayed_delete = nil
_G.delayed_create = nil
_G.delayed_delete_prefix = nil
ddl_callbacks = {}
local empty_schema = { spaces = {} }

local err_state_storage = errors.new_class("State storage error")

local function init_space_delete_batch_storage()
    local delete_space_batch = box.schema.space.create(
            '_DELETE_SPACE_BATCH',
            {
                format = {
                    { 'DELETE_BATCH_ID', 'string' },
                    { 'DELETE_TABLE_ARRAY', 'array' }
                }
            , if_not_exists = true
            }
    )

    delete_space_batch:create_index('_DELETE_SPACE_BATCH', {
        parts = { 'DELETE_BATCH_ID' },
        type = 'HASH',
        if_not_exists = true
    })

end

local function init_ddl_queue_space()

    if box.space['_DDL_QUEUE'] ~= nil then
        return
    end

    box.begin()
    local space = box.schema.space.create(
            '_DDL_QUEUE',
            {
                format = {
                    { 'ID', 'unsigned', is_nullable = false },
                    { 'OBJ_TYPE', 'string', is_nullable = false },
                    { 'OBJ_NAME', 'string', is_nullable = false },
                    { 'DDL_TYPE', 'string', is_nullable = false },
                    { 'DDL_PARAM', 'map', is_nullable = true }
                }
            ,
                if_not_exists = true
            }
    )
    box.schema.sequence.create('DDL_QUEUE_ID', { if_not_exists = true })
    space:create_index('ID', {
        type = 'TREE',
        unique = true,
        if_not_exists = true,
        sequence = 'DDL_QUEUE_ID',
        parts = { { field = 'ID', type = 'unsigned' } },
    })
    box.commit()

end

local function init_kafka_callbacks_logs()

    local cb_function_call_log_seq = box.schema.sequence.create('KAFKA_CALLBACK_FUNCTIONS_SEQ', { if_not_exists = true })

    local cb_function_call_log = box.schema.space.create(
            '_KAFKA_CALLBACK_FUNCTIONS_LOG',
            {
                format = {
                    { 'CALLBACK_LOG_ID', 'unsigned' },
                    { 'TOPIC_NAME', 'string' },
                    { 'PARTITION_NAME', 'string' },
                    { 'CALLBACK_FUNCTION_NAME', 'string' },
                    { 'CALLBACK_TIMESTAMP_START', 'number' },
                    { 'CALLBACK_TIMESTAMP_FINISH', 'number', is_nullable = true },
                    { 'CALLBACK_RESULT', 'boolean', is_nullable = true },
                    { 'CALLBACK_ERROR', 'string', is_nullable = true }
                }
            , if_not_exists = true
            }
    )

    cb_function_call_log:create_index('IX_CALLBACK_LOG_ID', {
        parts = { 'CALLBACK_LOG_ID' },
        type = 'TREE',
        if_not_exists = true
    })

end

local function init_kafka_error_msgs()
    local err_kafka_msg_seq = box.schema.sequence.create("KAFKA_ERRORS_SEQ", { if_not_exists = true })

    local err_kafka_err = box.schema.space.create(
            '_KAFKA_ERROR_MSG', {
                format = {
                    { 'KAFKA_ERROR_ID', 'unsigned' },
                    { 'TOPIC_NAME', 'string' },
                    { 'PARTITION_NAME', 'string' },
                    { 'OFFSET', 'unsigned' },
                    { 'KEY', 'string', is_nullable = true },
                    { 'VALUE', 'string', is_nullable = true },
                    { 'FIBER_NAME', 'string' },
                    { 'ERROR_TIMESTAMP', 'number' },
                    { 'ERROR_MSG', 'string' }

                }
            , if_not_exists = true
            }
    )

    err_kafka_err:create_index('KAFKA_ERROR_ID', {
        parts = { 'KAFKA_ERROR_ID' },
        type = 'TREE',
        if_not_exists = true
    })

end

local function insert_kafka_callback_log(topic_name, partition_name, cb_function_name)
    checks('string', 'string', 'string')
    local cb_function_call_log_seq = box.sequence['KAFKA_CALLBACK_FUNCTIONS_SEQ']

    if cb_function_call_log_seq == nil then
        return nil, "ERROR: KAFKA_CALLBACK_FUNCTIONS_SEQ sequence does not exists"
    end

    local cb_function_call_log = box.space['_KAFKA_CALLBACK_FUNCTIONS_LOG']

    if cb_function_call_log == nil then
        return nil, "ERROR: _KAFKA_CALLBACK_FUNCTIONS_LOG space does not exists"
    end

    local log_id = cb_function_call_log_seq:next()

    local _, err = err_state_storage:pcall(
            function()
                local tuple = cb_function_call_log:frommap({
                    CALLBACK_LOG_ID = log_id,
                    TOPIC_NAME = topic_name,
                    PARTITION_NAME = partition_name,
                    CALLBACK_FUNCTION_NAME = cb_function_name,
                    CALLBACK_TIMESTAMP_START = clock.time(),
                    CALLBACK_TIMESTAMP_FINISH = nil,
                    CALLBACK_RESULT = nil,
                    CALLBACK_ERROR = nil
                })

                cb_function_call_log:put(tuple)
                return true
            end)

    if err ~= nil then
        return log_id, err
    end

    return log_id, nil
end

local function set_kafka_callback_log_result(log_id, is_success, error_message)
    checks('number', 'boolean', '?string|?table')

    if type(error_message) == 'table' then
        error_message = table.concat(error_message, ';')
    end

    local cb_function_call_log = box.space['_KAFKA_CALLBACK_FUNCTIONS_LOG']

    if cb_function_call_log == nil then
        return false, "ERROR: _KAFKA_CALLBACK_FUNCTIONS_LOG space does not exists"
    end

    cb_function_call_log:update(log_id, {
        { '=', 'CALLBACK_TIMESTAMP_FINISH', clock.time() }
    , { '=', 'CALLBACK_RESULT', is_success }
    , { '=', 'CALLBACK_ERROR', error_message or box.NULL }
    })

    return true, nil

end

local function insert_kafka_error_msg(
        topic_name,
        partition_name,
        offset,
        key,
        value,
        fiber_name,
        error_timestamp,
        error_msg
)
    checks('string', 'string', 'number', '?string', '?string', 'string', 'number', 'string')

    local kafka_errors = box.space['_KAFKA_ERROR_MSG']

    if kafka_errors == nil then
        return false, "ERROR: _KAFKA_ERROR_MSG space does not exists"
    end

    local error_seq = box.sequence['KAFKA_ERRORS_SEQ']

    if error_seq == nil then
        return nil, "ERROR: KAFKA_ERRORS_SEQ sequence does not exists"
    end

    local _, err = err_state_storage:pcall(
            function()
                local tuple = kafka_errors:frommap({
                    KAFKA_ERROR_ID = error_seq:next(),
                    TOPIC_NAME = topic_name,
                    PARTITION_NAME = tostring(partition_name),
                    OFFSET = offset,
                    KEY = key,
                    VALUE = value,
                    FIBER_NAME = fiber_name,
                    ERROR_TIMESTAMP = error_timestamp,
                    ERROR_MSG = error_msg
                })
                kafka_errors:put(tuple)
                return true
            end)

    if err ~= nil then
        return false, err
    end

    return true, nil

end

local function insert_kafka_error_msgs(msgs)
    checks('table')

    local kafka_errors = box.space['_KAFKA_ERROR_MSG']

    if kafka_errors == nil then
        return false, "ERROR: _KAFKA_ERROR_MSG space does not exists"
    end

    local error_seq = box.sequence['KAFKA_ERRORS_SEQ']

    if error_seq == nil then
        return nil, "ERROR: KAFKA_ERRORS_SEQ sequence does not exists"
    end

    box.begin()
    local _, err = err_state_storage:pcall(
            function()
                for _, v in ipairs(msgs) do
                    local tuple = kafka_errors:frommap({
                        KAFKA_ERROR_ID = error_seq:next(),
                        TOPIC_NAME = v.topic_name,
                        PARTITION_NAME = tostring(v.partition_name),
                        OFFSET = v.offset,
                        KEY = v.key,
                        VALUE = v.value,
                        FIBER_NAME = v.fiber_name,
                        ERROR_TIMESTAMP = v.error_timestamp,
                        ERROR_MSG = v.error_msg
                    })

                    kafka_errors:put(tuple)
                end
                return true
            end)

    if err ~= nil then
        log.error(err)
        box.rollback()
        return false, err
    end

    box.commit()
    return true, nil

end
local function init_callback_function_repo()

    local callback_func = box.schema.space.create(
            '_KAFKA_CALLBACK_FUNCTIONS',
            {
                format = {
                    { 'CALLBACK_FUNCTION_NAME', 'string' },
                    { 'CALLBACK_FUNCTION_DESC', 'string', is_nullable = true },
                    { 'CALLBACK_FUNCTION_PARAM_SCHEMA', 'string', is_nullable = true }
                }
            , if_not_exists = true
            }
    )

    callback_func:create_index('IX_KAFKA_CB_FUNCTIONS', {
        parts = { 'CALLBACK_FUNCTION_NAME' },
        type = 'HASH',
        if_not_exists = true
    })
end

local function register_kafka_callback_function(function_name, function_desc, function_schema)
    checks('string', '?string', '?string')

    --checks if schema json
    local is_json, _ = pcall(json.decode, function_schema)

    if not is_json then
        return false, "ERROR: Function schema param must be valid json"
    end

    --check if space exists
    local kafka_callback = box.space["_KAFKA_CALLBACK_FUNCTIONS"]

    if kafka_callback == nil then
        return false, "ERROR: _KAFKA_CALLBACK_FUNCTIONS space does not exists"
    end

    local _, err = err_state_storage:pcall(
            function()
                local tuple = kafka_callback:frommap({
                    CALLBACK_FUNCTION_NAME = function_name,
                    CALLBACK_FUNCTION_DESC = function_desc,
                    CALLBACK_FUNCTION_PARAM_SCHEMA = function_schema
                })

                kafka_callback:put(tuple)
                return true
            end)

    if err ~= nil then
        return false, err
    end
end

local function register_scd_cb_function()
    local schema = [[
            {
            "name": "transferDataToScd_record",
            "type": "record",
            "fields": [
              {
                "name": "_space",
                "type": "string"
              },
              {
                "name": "_stage_data_table_name",
                "type": "string"
              },
              {
                "name": "_actual_data_table_name",
                "type": "string"
              },
              {
                "name": "_historical_data_table_name",
                "type": "string"
              },
              {
                "name": "_delta_number",
                "type": "int"
              }
            ]
          }
         ]]
    register_kafka_callback_function("transfer_data_to_scd_table_on_cluster_cb", "desc", schema)
end

local function ddl_queue_processor()
    log.info('DDL queue processor has been started')

    while true do
        if global.ddl_queue_fiber:status() == 'dead' then
            return
        end
        fiber.testcancel()

        -- getting current cluster ddl
        local current_state = yaml.decode(cartridge.get_schema())

        -- if item `schema` doesn't setup in cluser config then current state will be nil and next operations return error,
        -- thats why if scheme not found we create empty cluster scheme
        if current_state == nil then
            current_state = empty_schema
        end

        local tables_to_drop = {}
        local tables_to_create = {}
        local ddl_queue_space = box.space['_DDL_QUEUE']

        box.begin()
        for _, ddl_operation in ddl_queue_space:pairs() do
            ddl_callbacks[ddl_operation['ID']]['status'] = 'processing'
            ddl_callbacks[ddl_operation['ID']]['error'] = nil
            if ddl_operation['OBJ_TYPE'] == enums.obj_type.TABLE
                    and ddl_operation['DDL_TYPE'] == enums.ddl_type.CREATE_TABLE then
                current_state.spaces[ddl_operation['OBJ_NAME']] = ddl_operation['DDL_PARAM']
                tables_to_create[ddl_operation['OBJ_NAME']] = ddl_operation['ID']
                tables_to_drop[ddl_operation['OBJ_NAME']] = nil
            elseif ddl_operation['OBJ_TYPE'] == enums.obj_type.TABLE
                    and ddl_operation['DDL_TYPE'] == enums.ddl_type.DROP_TABLE then
                current_state.spaces[ddl_operation['OBJ_NAME']] = nil
                tables_to_drop[ddl_operation['OBJ_NAME']] = ddl_operation['ID']
            elseif ddl_operation['OBJ_TYPE'] == enums.obj_type.PREFIX
                    and ddl_operation['DDL_TYPE'] == enums.ddl_type.DROP_DATABASE then
                for space_name, _ in pairs(current_state.spaces) do
                    if string.startswith(space_name, ddl_operation['OBJ_NAME']) then
                        current_state.spaces[space_name] = nil
                        tables_to_drop[space_name] = ddl_operation['ID']
                    end
                end
            end
        end
        ddl_queue_space:truncate()
        box.commit()

        if misc_utils.table_length(tables_to_drop) ~= 0 or misc_utils.table_length(tables_to_create) ~= 0 then
            local tableList = {}
            for k, _ in pairs(tables_to_drop) do
                table.insert(tableList, k)
            end

            local _, err = cartridge.rpc_call('app.roles.adg_api',
                    'drop_spaces_on_cluster',
                    { tableList, nil, false },
                    { leader_only = false, timeout = 30 })

            if err ~= nil then
                log.error(err)
                for _, v in pairs(tables_to_drop) do
                    ddl_callbacks[v]['status'] = 'error'
                    ddl_callbacks[v]['error'] = err
                end
            end

            local retry_counter = 0;
            local max_retry = 3;

            for i = retry_counter, max_retry do
                local is_ddl_schema_patched, schema_patch_err = cartridge.set_schema(yaml.encode(current_state))
                if is_ddl_schema_patched ~= nil then
                    log.info('INFO: DDL operation runs successful')
                    for _, v in pairs(tables_to_create) do
                        ddl_callbacks[v]['status'] = 'done'
                        ddl_callbacks[v]['error'] = nil
                    end

                    for _, v in pairs(tables_to_drop) do
                        ddl_callbacks[v]['status'] = 'done'
                        ddl_callbacks[v]['error'] = nil
                    end
                    break
                end

                log.error(schema_patch_err)
                for _, v in pairs(tables_to_create) do
                    ddl_callbacks[v]['status'] = 'error'
                    ddl_callbacks[v]['error'] = err
                end

                fiber.sleep(math.exp(i))
            end
        end
        --wakeup

        for k, v in pairs(ddl_callbacks) do
            if v['status'] ~= 'created' then
                v['cond']:broadcast()
            end
        end
        fiber.sleep(0.5)
    end
end

local function init_ddl_queue_fiber()
    if global.ddl_queue_fiber == nil then
        global.ddl_queue_fiber = fiber.new(ddl_queue_processor)
    end
end

local function delete_kafka_callback_function(callback_function_name)
    checks('string')

    local kafka_callback = box.space["_KAFKA_CALLBACK_FUNCTIONS"]

    if kafka_callback == nil then
        return false, "ERROR: _KAFKA_CALLBACK_FUNCTIONS space does not exists"
    end

    local _, err = err_state_storage:pcall(
            function()
                kafka_callback:delete(callback_function_name)
                return true
            end)

    if err ~= nil then
        return false, err
    end
end

local function get_callback_functions()
    local callback_func_space = box.space["_KAFKA_CALLBACK_FUNCTIONS"]

    if callback_func_space == nil then
        return nil, "ERROR: _KAFKA_CALLBACK_FUNCTIONS space does not exists"
    end

    local result = {}

    for _, v in callback_func_space:pairs() do
        table.insert(result, v:tomap({ names_only = true }))
    end

    return result, nil
end

local function get_callback_function_schema(function_name)
    checks('string')

    local callback_func_space = box.space["_KAFKA_CALLBACK_FUNCTIONS"]
    if callback_func_space == nil then
        return nil, "ERROR: _KAFKA_CALLBACK_FUNCTIONS space does not exists"
    end

    local cb_function = callback_func_space:get(function_name)

    if cb_function == nil then
        return nil, string.format("ERROR: function %s does not exists", function_name)
    end

    return cb_function['CALLBACK_FUNCTION_PARAM_SCHEMA'], nil
end

local function validate_config(conf_new, conf_old)
    -- luacheck: no unused args

    local new_topology = conf_new.topology
    if new_topology == nil or new_topology.replicasets == nil then
        return true
    end

    local replicasets_cnt = 0 --ONLY One replicaset can exists

    for _, replica_set in pairs(conf_new.topology.replicasets) do
        if replica_set.roles['app.roles.adg_state'] then
            replicasets_cnt = replicasets_cnt + 1
            --[[ At least one vshard-storage (default) must have weight > 0
            if replica_set.weight ~= 0 then
                return false,'app.metrics.metrics_storage weight 1'
            end ]]
        end
    end

    if replicasets_cnt > 1 then
        return false, 'ERROR: Only one master must exists for app.roles.adg_state role'
    end

    return true
end

local function apply_config(conf, opts)

    schema_utils.init_schema_ddl()
    error_repository.init_error_repo('en')
    success_repository.init_success_repo('en')

    if opts.is_master then
        schema_utils.drop_all()
    end

    return true
end

local function stop()
    return true
end

local function get_metric()
    return metrics.export(role_name)
end

local function update_delete_batch_storage(batch_id, spaces)
    checks('string', 'table')
    local delete_space_batch = box.space['_DELETE_SPACE_BATCH']

    if delete_space_batch == nil then
        return nil, 'ERROR: _DELETE_SPACE_BATCH space not found'
    end

    local res, err = err_state_storage:pcall(function()
        local old_spaces = delete_space_batch:get(batch_id)

        if old_spaces == nil then
            local filter = fun.filter(function(v)
                return type(v) == 'string'
            end, spaces)      :totable()
            delete_space_batch:insert({ batch_id, filter })
        else
            local hash = {}
            local union = fun.chain(old_spaces['DELETE_TABLE_ARRAY'], spaces)
                             :filter(function(v)
                local check = hash[v]
                hash[v] = true
                return not check and type(v) == 'string' --only strings
            end)             :totable()

            delete_space_batch:update(batch_id, { { '=', 'DELETE_TABLE_ARRAY', union } })
        end
        return true
    end)

    return res, err
end

local function delayed_delete_on_cluster()
    local space = box.space['_DDL_QUEUE']

    if space == nil then
        return nil, 'ERROR: _DDL_QUEUE space not found'
    end

    local res, err = err_state_storage:pcall(function()
        local params = { iterator = 'EQ', limit = 10 }
        local spaces, err = space:select({}, params)

        if spaces == nil or err ~= nil then
            return nil, err
        else
            local tableList = {}
            for _, v in pairs(spaces) do
                --- filter create and delete for one object
                if v['OBJ_TYPE'] == 'space' then
                    table.insert(tableList, v['OBJ_NAME'])
                end
            end
            local res, err = cartridge.rpc_call('app.roles.adg_api',
                    'drop_spaces_on_cluster',
                    { tableList },
                    { leader_only = true, timeout = 30 })
            for _, s in pairs(spaces) do
                space:delete(s[1])
                if global.ddl_request_queue[s['OBJ_NAME']] ~= nil then
                    global.ddl_request_queue[s['OBJ_NAME']]:broadcast()
                end
            end
            return res, err
        end
    end)

    return res, err
end

local function delayed_delete_prefix(prefix)
    checks('string')

    local space = box.space['_DDL_QUEUE']

    if space == nil then
        return nil, 'ERROR: _DDL_QUEUE space not found'
    end

    local tuple, err
    box.begin()
    tuple, err = space:insert(
            { nil, enums.obj_type.PREFIX, prefix, enums.ddl_type.DROP_DATABASE, nil })
    ddl_callbacks[tuple['ID']] = {}
    ddl_callbacks[tuple['ID']]['cond'] = fiber.cond()
    ddl_callbacks[tuple['ID']]['status'] = 'created'
    box.commit()

    local w = fiber.new(function()
        local ok = ddl_callbacks[tuple['ID']]['cond']:wait(20)

        if not ok then
            ddl_callbacks[tuple['ID']] = nil
            return { code = 'API_DDL_QUEUE_004', msg = 'ERROR: ddl reques timeout' }
        end

        if ddl_callbacks[tuple['ID']]['status'] == 'error' then
            return { code = 'API_DDL_QUEUE_004', msg = ddl_callbacks[tuple['ID']]['error'] }

        end
        ddl_callbacks[tuple['ID']] = nil
        return nil
    end)

    w:name('delayed_prefix_delete')
    w:set_joinable(true)

    local ok, res = w:join()
    if not ok or res ~= nil then
        return ok, res
    end

    return true, nil
end

local function delayed_create(spaces)
    checks('table')

    local space = box.space['_DDL_QUEUE']

    if space == nil then
        return nil, 'ERROR: _DDL_QUEUE space not found'
    end

    local tuple, err
    box.begin()
    for k, v in pairs(spaces) do
        tuple, err = space:insert(
                { nil, enums.obj_type.TABLE, k, enums.ddl_type.CREATE_TABLE, v })
        ddl_callbacks[tuple['ID']] = {}
        ddl_callbacks[tuple['ID']]['cond'] = fiber.cond()
        ddl_callbacks[tuple['ID']]['status'] = 'created'
    end
    box.commit()
    local w = fiber.new(function()
        local ok = ddl_callbacks[tuple['ID']]['cond']:wait(20)

        if not ok then
            ddl_callbacks[tuple['ID']] = nil
            return { code = 'API_DDL_QUEUE_004', msg = 'ERROR: ddl reques timeout' }
        end

        if ddl_callbacks[tuple['ID']]['status'] == 'error' then
            return { code = 'API_DDL_QUEUE_004', msg = ddl_callbacks[tuple['ID']]['error'] }

        end
        ddl_callbacks[tuple['ID']] = nil
        return nil
    end)

    w:name('delayed_create')
    w:set_joinable(true)

    local ok, res = w:join()
    if not ok or res ~= nil then
        return ok, res
    end

    return true, nil
end

local function delayed_delete(spaces)
    checks('table')

    local space = box.space['_DDL_QUEUE']
    local tuple, err
    if space == nil then
        return nil, 'ERROR: _DDL_QUEUE space not found'
    end
    box.begin()
    for _, v in pairs(spaces) do
        tuple, err = space:insert(
                { nil, enums.obj_type.TABLE, v, enums.ddl_type.DROP_TABLE, nil })
        ddl_callbacks[tuple['ID']] = {}
        ddl_callbacks[tuple['ID']]['cond'] = fiber.cond()
        ddl_callbacks[tuple['ID']]['status'] = 'created'
    end
    box.commit()
    local w = fiber.new(function()
        local ok = ddl_callbacks[tuple['ID']]['cond']:wait(20)

        if not ok then
            ddl_callbacks[tuple['ID']] = nil
            return { code = 'API_DDL_QUEUE_004', msg = 'ERROR: ddl reques timeout' }
        end

        if ddl_callbacks[tuple['ID']]['status'] == 'error' then
            return { code = 'API_DDL_QUEUE_004', msg = ddl_callbacks[tuple['ID']]['error'] }

        end
        ddl_callbacks[tuple['ID']] = nil
        return nil
    end)

    w:name('delayed_delete')
    w:set_joinable(true)

    local ok, res = w:join()
    if not ok or res ~= nil then
        return ok, res
    end

    return true, nil

end

local function get_tables_from_delete_batch(batch_id)
    checks('string')

    local delete_space_batch = box.space['_DELETE_SPACE_BATCH']

    if delete_space_batch == nil then
        return nil, 'ERROR: _DELETE_SPACE_BATCH space not found'
    end

    local batch = delete_space_batch:get(batch_id)

    if batch ~= nil then
        return batch['DELETE_TABLE_ARRAY']
    else
        return {}
    end

end

local function remove_delete_batch(batch_id)
    checks('string')

    local delete_space_batch = box.space['_DELETE_SPACE_BATCH']

    if delete_space_batch == nil then
        return nil, 'ERROR: _DELETE_SPACE_BATCH space not found'
    end

    delete_space_batch:delete(batch_id)

    return true
end

local function get_schema()
    for _, instance_uri in pairs(cartridge_rpc.get_candidates('app.roles.adg_storage', { leader_only = true })) do
        return cartridge_rpc.call('app.roles.adg_storage', 'get_schema', nil, { uri = instance_uri })
    end
end

local function init(opts)
    rawset(_G, 'ddl', { get_schema = get_schema })

    if opts.is_master then
        init_space_delete_batch_storage()
        init_ddl_queue_space()
        init_kafka_callbacks_logs()
        init_kafka_error_msgs()
        init_callback_function_repo()
        register_scd_cb_function()
        init_ddl_queue_fiber()
        box.space._DDL_QUEUE:truncate()
    end
    global:new('ddl_queue_fiber')
    global:new('ddl_request_queue')

    _G.update_delete_batch_storage = update_delete_batch_storage
    _G.get_tables_from_delete_batch = get_tables_from_delete_batch
    _G.remove_delete_batch = remove_delete_batch
    _G.insert_kafka_callback_log = insert_kafka_callback_log
    _G.set_kafka_callback_log_result = set_kafka_callback_log_result
    _G.insert_kafka_error_msg = insert_kafka_error_msg
    _G.insert_kafka_error_msgs = insert_kafka_error_msgs
    _G.register_kafka_callback_function = register_kafka_callback_function
    _G.get_callback_functions = get_callback_functions
    _G.get_callback_function_schema = get_callback_function_schema
    _G.delete_kafka_callback_function = delete_kafka_callback_function
    _G.delayed_delete_on_cluster = delayed_delete_on_cluster
    _G.delayed_delete = delayed_delete
    _G.delayed_create = delayed_create
    _G.delayed_delete_prefix = delayed_delete_prefix

    local httpd = cartridge.service_get('httpd')
    httpd:route({ method = 'GET', path = '/metrics' }, prometheus.collect_http)

    return true
end

return {
    role_name = role_name,
    init = init,
    stop = stop,
    validate_config = validate_config,
    apply_config = apply_config,
    dependencies = {
        'cartridge.roles.crud-router',
        'cartridge.roles.vshard-router'
    },
    get_metric = get_metric,
    get_schema = get_schema,
    update_delete_batch_storage = update_delete_batch_storage,
    get_tables_from_delete_batch = get_tables_from_delete_batch,
    remove_delete_batch = remove_delete_batch,
    insert_kafka_callback_log = insert_kafka_callback_log,
    set_kafka_callback_log_result = set_kafka_callback_log_result,
    insert_kafka_error_msg = insert_kafka_error_msg,
    insert_kafka_error_msgs = insert_kafka_error_msgs,
    register_kafka_callback_function = register_kafka_callback_function,
    get_callback_functions = get_callback_functions,
    get_callback_function_schema = get_callback_function_schema,
    delete_kafka_callback_function = delete_kafka_callback_function,
    delayed_delete_on_cluster = delayed_delete_on_cluster,
    delayed_delete = delayed_delete,
    delayed_create = delayed_create,
    delayed_delete_prefix = delayed_delete_prefix
}
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
--- DateTime: 8/4/20 4:14 PM
---
local fiber = require('fiber')
local log = require('log')
local checks = require('checks')
local clock = require('clock')


local kafka_msg_commit_transformation = {}
kafka_msg_commit_transformation.__index = kafka_msg_commit_transformation
kafka_msg_commit_transformation.__type = 'transformation'
kafka_msg_commit_transformation.__call = function (cls, ...)
    return cls.new(...)
end

local function process(consumer,msg,error_dest,fiber_name)
    local raw_msg = msg.raw_msg
    if raw_msg == nil then
        return nil
    end

    local _, err = consumer:commit(raw_msg)

    if err ~= nil then
        log.error(err)
        if error_dest ~= nil then
            error_dest:put({msg = msg.msg,
                            err = err,
                            fiber = fiber_name,
                            timestamp = clock.time()})
        end
        return nil
    end

    local _,err = consumer:commit_sync()

    if err ~= nil then
        log.error(err)
        if not string.match(err,'No offset stored') then
            if error_dest ~= nil then
                error_dest:put({msg = msg.msg,
                                err = err,
                                fiber = fiber_name,
                                timestamp = clock.time()})
            end
            return nil
        end
    end

    msg.raw_msg = nil
    return msg
end

local function create_fiber(self,process_function, fiber_name,source,error_dest,consumer)
    local process_fiber = fiber.new(
            function()
                while true do
                    if (source:is_closed() or self.process_channel:is_closed()) then
                        log.warn('WARN: Channels closed in fiber %s', fiber_name)
                        return
                    end
                    local input = source:get()
                    if input ~= nil then
                        local result = process_function(consumer,input,error_dest,fiber_name)
                        if result ~= nil then
                            local sent = self.process_channel:put(result)
                            if not sent then
                                log.error("ERROR: %s fiber send error",fiber_name)
                                if error_dest ~= nil then
                                    error_dest:put({msg = result.msg,
                                                    err = string.format("ERROR: %s fiber send error",fiber_name),
                                                    fiber = fiber_name,
                                                    timestamp = clock.time()})
                                end
                            end
                        end
                    end
                    fiber.yield()
                end
            end)
    process_fiber:name(fiber_name)
    return process_fiber
end

function kafka_msg_commit_transformation.init(channel_capacity,source,error_dest,consumer)
    local self = setmetatable({}, kafka_msg_commit_transformation)
    self.process_channel = fiber.channel(channel_capacity)
    self.process_fiber = create_fiber(self,process,"kafka_msg_commit_fiber",source,error_dest,consumer)
    return self
end

function kafka_msg_commit_transformation.get_result_channel(self)
    return self.process_channel
end

return kafka_msg_commit_transformation
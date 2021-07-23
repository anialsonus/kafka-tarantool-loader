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

local checks = require('checks')
local log = require('log')
local message_utils = require('app.messages.utils.message_utils')
local file_utils = require('app.utils.file_utils')
local repository_utils = require('app.messages.utils.repository_utils')
local fio = require('fio')
local json = require('json')

---@type table -that contains error operations messages.
local error_codes = {}

---@type table - that contains error http-response codes.
local http_response_codes = {}

---init_error_repo - initialization method, that load error messages repository from files in 'app/messages/repos/'.
---@param language string - language of files to seek.
local function init_error_repo(language)
    checks('string')
    local path_to_repo = package.searchroot() .. '/app/messages/repos/'
    local error_repo_files_path = path_to_repo .. language .. '/errors'
    local error_repo_files = file_utils.get_files_in_directory(error_repo_files_path, '*.yml')
    error_codes = repository_utils.reload_repo_from_files(error_repo_files)
    local error_repo_resp_files_path = error_repo_files_path .. '/response_codes'
    local error_repo_resp_files = file_utils.get_files_in_directory(error_repo_resp_files_path, '*.yml')
    http_response_codes = repository_utils.reload_repo_from_files(error_repo_resp_files)
end

---get_error_code - the method, that returns the error message in JSON-string format
---with additional opts from error messages repository.
---@param code string - repository message code.
---@param opts table - additional opts.
---@return string - the error in json-string format.
local function get_error_code(code,opts)
    checks('string', '?table')
    local err = message_utils.get_message_code(error_codes,code,opts)
    log.error(err)
    return err
end

---return_http_response - the method, that returns http-response with error message.
---@param code string - repository message code.
---@param opts table - additional opts.
---@param body string - http-response message body.
---@return table - http-response with content-type = application/json.
local function return_http_response(code,opts,body)
    checks('string','?table|?string','?string|?table')
    local http_code = message_utils.get_message_code(http_response_codes,code)

    if type(opts) == 'string' then
        opts = json.decode(opts)
    end

    if body == nil  then
        body = get_error_code(code,opts)
    end

    if type(body) == 'table' then
        body = json.encode(body)
    end

    return {
        status = tonumber(http_code),
        headers = { ['content-type'] = 'application/json' },
        body = body}
end


return {
    get_error_code = get_error_code,
    return_http_response = return_http_response,
    init_error_repo = init_error_repo
}
local websocket = require "websocket"
local log = require "log"
local sys = require "sys"
local misc = require "misc"
local util_mobile = require "util_mobile"
local util_notify = require "util_notify"
local util_temperature = require "util_temperature"
local nvm = require "nvm"

config = nvm.para

local function parse_config(config_text)
    -- 参数检查
    if type(config_text) ~= "string" or config_text == "" then
        return nil, "配置文本不能为空"
    end

    -- 预处理配置文本
    local processed_text = config_text:gsub("module%(%.%.%.%)", ""):gsub("%-%-[^\n]*", ""):gsub("\n%s*\n", "\n")

    -- 创建一个环境table来捕获配置变量
    local env = {}
    local chunk = loadstring(processed_text)
    if chunk then
        setfenv(chunk, env)
        chunk()
    else
        log.info("set_config", "Failed to parse_config")
    end

    return env
end

local function handleTask(ws, json_data)

    log.info("websocket", json_data.task)

    -- 处理task类型的消息
    if json_data.type == "task" and json_data.taskId then
        -- 执行对应的task函数
        sys.taskInit(function()
            local result = nil
            local error = nil

            -- 执行task函数
            local success, err = pcall(function()
                -- 根据taskid执行不同的任务
                if json_data.task == "get_temperature" then
                    -- 调用温度查询函数
                    result = util_temperature.get()
                elseif json_data.task == "at_cmd" then
                    -- 检查参数
                    if not json_data.command then
                        error = "缺少必要参数: command"
                    else
                        -- 执行AT指令
                        local response = ""
                        local taskId = json_data.taskId
                        
                        -- 使用一个全局的响应处理函数
                        local function atResponseHandler(cmd, success, resp, inter)
                            if inter then
                                response = response .. inter .. "\n"
                            end
                            if resp then
                                response = response .. resp
                            end
                            
                            -- 发送执行结果给服务端
                            local response_data = {
                                type = "task_result",
                                taskId = taskId,
                                task = json_data.task,
                                result = response,
                                error = nil
                            }
                            ws:send(json.encode(response_data), true)
                        end
                        
                        -- 发送AT指令，直接使用回调函数
                        ril.request(json_data.command, nil, atResponseHandler)
                        -- 提前返回，等待回调处理
                        return
                    end
                elseif json_data.task == "send_sms" then
                    -- 检查参数
                    if not json_data.rcv_phone or not json_data.content then
                        error = "缺少必要参数: rcv_phone 或 content"
                    else
                        local sms_success, sms_err = pcall(function()
                            sms.send(json_data.rcv_phone, json_data.content)
                        end)
                        if sms_success then
                            result = "短信发送成功"
                        else
                            error = "短信发送失败: " .. tostring(sms_err)
                        end
                    end
                elseif json_data.task == "get_config" then
                    -- 直接读取/nvm_para.lua文件内容
                    local file = io.open("/nvm_para.lua", "r")
                    if file then
                        local content = file:read("*a")
                        file:close()
                        result = content
                    else
                        error = "无法读取/nvm_para.lua文件"
                    end
                elseif json_data.task == "set_config" then
                    if not json_data.configText or type(json_data.configText) ~= "string" then
                        error = "缺少必要参数: configText (必须是字符串)"
                    else
                        -- 解析配置
                        local config_table, err = parse_config(json_data.configText)
                        if not config_table then
                            log.info('set_config', err)
                        else
                            for k, v in pairs(config_table) do
                                if type(v) == 'number' or type(v) == 'string' or type(v) == "boolean" or type(v) == "table" then
                                    nvm.set(k, v)
                                end
                            end
                            config = nvm.para
                            -- 直接写入 configText 到 /nvm_para.lua 方便读取修改
                            local file = io.open("/nvm_para.lua", "w+")
                            if file then
                                file:write(json_data.configText)
                                file:close()
                            else
                                error = "无法写入/nvm_para.lua文件"
                            end
                            result = { success = true }
                        end
                    end
                else
                    error = "未知的任务类型: " .. (json_data.task or "nil")
                end
            end)

            if not success then
                error = err
            end

            -- 发送执行结果给服务端
            local response = { type = "task_result", taskId = json_data.taskId, task = json_data.task, result = result, error = error }

            if not error then
                log.info('websocket', error)
            end

            ws:send(json.encode(response), true)
        end)
    end
end

local function startWebSocket()

    log.info("websocket", "开始连接")

    -- websocket 连接
    -- 使用 config.WEBSOCKET_URL 获取地址
    local ws = websocket.new(config.WEBSOCKET_URL)

    ws:on("open", function()
        log.info("websocket", "连接已打开")
        -- 发送JSON数据
        local json_data = { type = "online", imei = misc.getImei(), phone = util_mobile.getNumber() }
        ws:send(json.encode(json_data), true)
    end)

    ws:on("message", function(data)
        -- 解析JSON数据
        local success, json_data = pcall(json.decode, data)
        if success then
            handleTask(ws, json_data)
        end
    end)

    ws:on("close", function()
        log.info("websocket", "连接关闭")
    end)

    ws:on("error", function(ws, err)
        log.error("websocket", "连接错误", err)
    end)

    -- 启动WebSocket任务
    ws:start(120)
end

return { start = startWebSocket }

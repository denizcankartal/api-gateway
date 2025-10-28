-- Initialization script - runs once when nginx starts
-- Set up global configurations and utilities

local _M = {}

-- Helper: Get environment variable as number with validation
local function get_env_number(key, default)
    local val = os.getenv(key)
    if val then
        local num = tonumber(val)
        if not num then
            ngx.log(ngx.WARN, "Invalid number for ", key, ": ", val, " - using default: ", default)
            return default
        end
        return num
    end
    return default
end

-- Global configuration
_M.config = {
    -- Rate limiting defaults
    rate_limit = {
        enabled = true,
        requests_per_minute = get_env_number("RATE_LIMIT_RPM", 100),
        burst = get_env_number("RATE_LIMIT_BURST", 20)
    },

    -- Circuit breaker defaults
    circuit_breaker = {
        enabled = true,
        failure_threshold = get_env_number("CB_FAILURE_THRESHOLD", 5),
        success_threshold = get_env_number("CB_SUCCESS_THRESHOLD", 2),
        timeout = get_env_number("CB_TIMEOUT", 30),
        window = get_env_number("CB_WINDOW", 60)
    }
}

-- Circuit breaker states (shared constants)
_M.CIRCUIT_STATES = {
    CLOSED = "closed",
    OPEN = "open",
    HALF_OPEN = "half_open"
}

-- Utility function: Get client identifier
function _M.get_client_id()
    local client_id = ngx.var.http_x_api_key
    if not client_id or client_id == "" then
        client_id = ngx.var.remote_addr
    end
    return client_id
end

-- Utility function: JSON response with error handling
function _M.json_response(status, data)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"

    local ok, json = pcall(require("cjson").encode, data)
    if not ok then
        ngx.log(ngx.ERR, "Failed to encode JSON: ", json)
        ngx.say('{"error":"Internal error"}')
    else
        ngx.say(json)
    end
    ngx.exit(status)
end

-- Export module
_G.gateway = _M

ngx.log(ngx.NOTICE, "API Gateway initialized - Rate limit: ",
        _M.config.rate_limit.requests_per_minute, " RPM, CB threshold: ",
        _M.config.circuit_breaker.failure_threshold)

return _M

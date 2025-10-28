-- Initialization script - runs once when nginx starts
-- Set up global configurations and utilities

local _M = {}

-- Global configuration
_M.config = {
    -- Rate limiting defaults
    rate_limit = {
        enabled = true,
        requests_per_minute = 100,
        burst = 20
    },

    -- Circuit breaker defaults
    circuit_breaker = {
        enabled = true,
        failure_threshold = 5,      -- Open after 5 failures
        success_threshold = 2,       -- Close after 2 successes
        timeout = 30,                -- Try again after 30 seconds
        window = 60                  -- Failure window in seconds
    }
}

-- Utility function: Get client identifier
function _M.get_client_id()
    local client_id = ngx.var.http_x_api_key
    if not client_id or client_id == "" then
        client_id = ngx.var.remote_addr
    end
    return client_id
end

-- Utility function: JSON response
function _M.json_response(status, data)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(require("cjson").encode(data))
    ngx.exit(status)
end

-- Export module
_G.gateway = _M

ngx.log(ngx.NOTICE, "API Gateway initialized successfully")

return _M

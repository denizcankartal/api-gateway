-- Circuit Breaker Pattern Implementation
-- Prevents cascading failures by failing fast when service is unhealthy

local circuit_dict = ngx.shared.circuit_breaker
local metrics_dict = ngx.shared.metrics

-- Configuration
local config = {
    failure_threshold = tonumber(os.getenv("CB_FAILURE_THRESHOLD")) or 5,
    success_threshold = tonumber(os.getenv("CB_SUCCESS_THRESHOLD")) or 2,
    timeout = tonumber(os.getenv("CB_TIMEOUT")) or 30,
    window = tonumber(os.getenv("CB_WINDOW")) or 60
}

-- Circuit states
local CLOSED = "closed"
local OPEN = "open"
local HALF_OPEN = "half_open"

-- Get circuit state
local function get_circuit_state(service)
    local state_key = "cb:" .. service .. ":state"
    local state = circuit_dict:get(state_key) or CLOSED
    return state
end

-- Set circuit state
local function set_circuit_state(service, state)
    local state_key = "cb:" .. service .. ":state"
    circuit_dict:set(state_key, state)
end

-- Check if circuit should open
local function should_open(service)
    local failures_key = "cb:" .. service .. ":failures"
    local window_key = "cb:" .. service .. ":window_start"

    local failures = circuit_dict:get(failures_key) or 0
    local window_start = circuit_dict:get(window_key) or ngx.now()

    -- Reset if window expired
    if ngx.now() - window_start > config.window then
        circuit_dict:set(failures_key, 0)
        circuit_dict:set(window_key, ngx.now())
        return false
    end

    return failures >= config.failure_threshold
end

-- Check if circuit should close
local function should_close(service)
    local successes_key = "cb:" .. service .. ":successes"
    local successes = circuit_dict:get(successes_key) or 0
    return successes >= config.success_threshold
end

-- Main execution
local route = ngx.var.route_name or "unknown"
local state = get_circuit_state(route)
local now = ngx.now()

if state == OPEN then
    -- Check if timeout expired
    local open_time_key = "cb:" .. route .. ":open_time"
    local open_time = circuit_dict:get(open_time_key) or now

    if now - open_time >= config.timeout then
        -- Move to half-open state
        set_circuit_state(route, HALF_OPEN)
        circuit_dict:set("cb:" .. route .. ":successes", 0)
        ngx.log(ngx.WARN, "Circuit breaker for ", route, " moved to HALF_OPEN")
    else
        -- Circuit still open - reject request
        metrics_dict:incr("metric:circuit_open:" .. route, 1, 0)
        ngx.status = 503
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"Service temporarily unavailable","code":"CIRCUIT_OPEN","retry_after":' ..
                math.ceil(config.timeout - (now - open_time)) .. '}')
        ngx.exit(503)
    end
end

-- Log response handler to track failures/successes
ngx.ctx.circuit_breaker_route = route
ngx.ctx.circuit_breaker_state = state

-- Register log phase handler
local function log_handler()
    local ctx_route = ngx.ctx.circuit_breaker_route
    if not ctx_route then return end

    local status = ngx.status
    local ctx_state = ngx.ctx.circuit_breaker_state

    -- Track failures (5xx errors)
    if status >= 500 then
        local failures_key = "cb:" .. ctx_route .. ":failures"
        local window_key = "cb:" .. ctx_route .. ":window_start"

        circuit_dict:incr(failures_key, 1, 0)
        if not circuit_dict:get(window_key) then
            circuit_dict:set(window_key, ngx.now())
        end

        -- Check if should open
        if should_open(ctx_route) then
            set_circuit_state(ctx_route, OPEN)
            circuit_dict:set("cb:" .. ctx_route .. ":open_time", ngx.now())
            ngx.log(ngx.ERR, "Circuit breaker OPENED for ", ctx_route)
            metrics_dict:incr("metric:circuit_opened:" .. ctx_route, 1, 0)
        end
    -- Track successes (2xx, 3xx, 4xx)
    elseif status < 500 and ctx_state == HALF_OPEN then
        local successes_key = "cb:" .. ctx_route .. ":successes"
        circuit_dict:incr(successes_key, 1, 0)

        -- Check if should close
        if should_close(ctx_route) then
            set_circuit_state(ctx_route, CLOSED)
            circuit_dict:set("cb:" .. ctx_route .. ":failures", 0)
            circuit_dict:set("cb:" .. ctx_route .. ":successes", 0)
            ngx.log(ngx.NOTICE, "Circuit breaker CLOSED for ", ctx_route)
            metrics_dict:incr("metric:circuit_closed:" .. ctx_route, 1, 0)
        end
    end
end

-- Schedule log phase handler
ngx.log_by_lua(log_handler)

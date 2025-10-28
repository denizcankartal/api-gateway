-- Circuit Breaker Pattern Implementation
-- Prevents cascading failures by failing fast when service is unhealthy

local circuit_dict = ngx.shared.circuit_breaker
local metrics_dict = ngx.shared.metrics

-- Use global configuration from init.lua
local config = _G.gateway.config.circuit_breaker
local CLOSED = _G.gateway.CIRCUIT_STATES.CLOSED
local OPEN = _G.gateway.CIRCUIT_STATES.OPEN
local HALF_OPEN = _G.gateway.CIRCUIT_STATES.HALF_OPEN

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
        state = HALF_OPEN
    else
        -- Circuit still open - reject request
        local retry_after = math.ceil(config.timeout - (now - open_time))
        if retry_after < 0 then retry_after = 0 end

        metrics_dict:incr("metric:circuit_open:" .. route, 1, 0)
        ngx.status = 503
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Retry-After"] = tostring(retry_after)
        ngx.say('{"error":"Service temporarily unavailable","code":"CIRCUIT_OPEN","retry_after":' ..
                retry_after .. '}')
        ngx.exit(503)
    end
end

-- Store context for log phase
ngx.ctx.circuit_breaker_route = route
ngx.ctx.circuit_breaker_state = state

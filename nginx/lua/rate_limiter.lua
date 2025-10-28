-- Rate Limiter using Token Bucket Algorithm
-- Protects backend services from abuse

local rate_limit_dict = ngx.shared.rate_limit
local metrics_dict = ngx.shared.metrics

-- Use global configuration from init.lua
local rate_limit_cfg = _G.gateway.config.rate_limit
local config = {
    enabled = rate_limit_cfg.enabled ~= false,
    rate = rate_limit_cfg.requests_per_minute,
    burst = rate_limit_cfg.burst
}

local TOKEN_TTL = 120

-- Token bucket rate limiter
local function check_rate_limit(client_id, route)
    if not config.enabled then
        return true, config.burst, 0
    end

    if config.rate <= 0 then
        return true, config.burst, 0
    end

    local key = "rl:" .. route .. ":" .. client_id
    local rate_per_second = config.rate / 60
    local now = ngx.now()

    -- Get current state
    local last_time, err = rate_limit_dict:get(key .. ":time")
    if not last_time then
        last_time = now
    end

    local tokens, err = rate_limit_dict:get(key .. ":tokens")
    if not tokens then
        tokens = config.burst
    end

    -- Calculate new tokens
    local elapsed = now - last_time
    tokens = math.min(config.burst, tokens + (elapsed * rate_per_second))

    -- Check if request can proceed
    if tokens >= 1 then
        tokens = tokens - 1
        last_time = now
        rate_limit_dict:set(key .. ":tokens", tokens, TOKEN_TTL)
        rate_limit_dict:set(key .. ":time", last_time, TOKEN_TTL)
        return true, math.floor(tokens), 0
    else
        -- Rate limit exceeded
        rate_limit_dict:set(key .. ":tokens", tokens, TOKEN_TTL)
        rate_limit_dict:set(key .. ":time", last_time, TOKEN_TTL)
        return false, 0, math.ceil((1 - tokens) / rate_per_second)
    end
end

-- Main execution
local client_id = _G.gateway.get_client_id()
local route = ngx.var.route_name or "unknown"

local allowed, remaining, retry_after = check_rate_limit(client_id, route)

if not allowed then
    -- Increment rate limit counter
    local counter_key = "metric:rate_limited:" .. route
    metrics_dict:incr(counter_key, 1, 0)

    -- Set rate limit headers
    ngx.header["X-RateLimit-Limit"] = config.rate
    ngx.header["X-RateLimit-Remaining"] = "0"
    ngx.header["Retry-After"] = tostring(retry_after)

    -- Return 429 Too Many Requests
    ngx.status = 429
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Rate limit exceeded","code":"RATE_LIMITED","retry_after":' .. retry_after .. '}')
    ngx.exit(429)
end

-- Set rate limit headers for successful requests
ngx.header["X-RateLimit-Limit"] = config.rate
ngx.header["X-RateLimit-Remaining"] = tostring(remaining)

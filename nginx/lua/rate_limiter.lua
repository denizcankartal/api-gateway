-- Rate Limiter using Token Bucket Algorithm
-- Protects backend services from abuse

local rate_limit_dict = ngx.shared.rate_limit
local metrics_dict = ngx.shared.metrics

-- Configuration
local config = {
    rate = tonumber(os.getenv("RATE_LIMIT_RPM")) or 100,  -- requests per minute
    burst = tonumber(os.getenv("RATE_LIMIT_BURST")) or 20  -- burst capacity
}

-- Get client identifier
local function get_client_id()
    return gateway.get_client_id()
end

-- Token bucket rate limiter
local function check_rate_limit(client_id, route)
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
        rate_limit_dict:set(key .. ":tokens", tokens)
        rate_limit_dict:set(key .. ":time", now)
        return true
    else
        -- Rate limit exceeded
        return false, math.ceil((1 - tokens) / rate_per_second)
    end
end

-- Main execution
local client_id = get_client_id()
local route = ngx.var.route_name or "unknown"

local allowed, retry_after = check_rate_limit(client_id, route)

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

-- Metrics Endpoint
-- Exposes gateway metrics in Prometheus format

local metrics_dict = ngx.shared.metrics
local circuit_dict = ngx.shared.circuit_breaker
local rate_limit_dict = ngx.shared.rate_limit

-- Helper to output metric
local function output_metric(name, type, help, value)
    ngx.say("# HELP ", name, " ", help)
    ngx.say("# TYPE ", name, " ", type)
    ngx.say(name, " ", value)
end

-- Helper to output metric with labels
local function output_metric_with_labels(name, labels, value)
    local label_str = ""
    for k, v in pairs(labels) do
        if label_str ~= "" then
            label_str = label_str .. ","
        end
        label_str = label_str .. k .. '="' .. v .. '"'
    end
    ngx.say(name, "{", label_str, "} ", value)
end

-- Set content type
ngx.header["Content-Type"] = "text/plain; version=0.0.4"

-- Gateway info
output_metric("gateway_info", "gauge", "API Gateway information", 1)

-- Get all metric keys
local keys = metrics_dict:get_keys(0)

-- Rate limit metrics
ngx.say("\n# Rate Limiting Metrics")
for _, key in ipairs(keys) do
    if key:match("^metric:rate_limited:") then
        local route = key:match("^metric:rate_limited:(.+)")
        local count = metrics_dict:get(key) or 0
        output_metric_with_labels("gateway_rate_limited_total", {route=route}, count)
    end
end

-- Circuit breaker metrics
ngx.say("\n# Circuit Breaker Metrics")
for _, key in ipairs(keys) do
    if key:match("^metric:circuit_open:") then
        local route = key:match("^metric:circuit_open:(.+)")
        local count = metrics_dict:get(key) or 0
        output_metric_with_labels("gateway_circuit_open_total", {route=route}, count)
    elseif key:match("^metric:circuit_opened:") then
        local route = key:match("^metric:circuit_opened:(.+)")
        local count = metrics_dict:get(key) or 0
        output_metric_with_labels("gateway_circuit_opened_events", {route=route}, count)
    elseif key:match("^metric:circuit_closed:") then
        local route = key:match("^metric:circuit_closed:(.+)")
        local count = metrics_dict:get(key) or 0
        output_metric_with_labels("gateway_circuit_closed_events", {route=route}, count)
    end
end

-- Circuit breaker states
ngx.say("\n# Current Circuit States")
local cb_keys = circuit_dict:get_keys(0)
for _, key in ipairs(cb_keys) do
    if key:match(":state$") then
        local route = key:match("^cb:(.+):state")
        local state = circuit_dict:get(key) or "closed"
        local state_value = (state == "open") and 1 or (state == "half_open") and 0.5 or 0
        output_metric_with_labels("gateway_circuit_state", {route=route, state=state}, state_value)
    end
end

-- Nginx metrics
ngx.say("\n# Nginx Metrics")
output_metric("gateway_connections_active", "gauge", "Active connections", ngx.var.connections_active or 0)
output_metric("gateway_connections_reading", "gauge", "Connections reading", ngx.var.connections_reading or 0)
output_metric("gateway_connections_writing", "gauge", "Connections writing", ngx.var.connections_writing or 0)
output_metric("gateway_connections_waiting", "gauge", "Connections waiting", ngx.var.connections_waiting or 0)

ngx.exit(200)

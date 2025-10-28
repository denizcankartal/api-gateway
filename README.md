API gateway using nginx + Lua. Simple and fast with essentials only.

## Scope

1. **Entry Point** - Single access point for all traffic
2. **Routing** - Path-based routing to the appropriate service
3. **Security** - TLS termination, security headers
4. **Protection** - Rate limiting + circuit breaker
5. **Observability** - JSON logs + Prometheus metrics

## Quick Start

```bash
# 1. Copy environment template
cp .env.example .env

# 2. Start gateway
docker-compose up -d

# 3. Check health
curl http://localhost/health

# 4. View metrics
curl http://localhost/metrics
```

## Adding a New Service

To add a new service, follow these steps:

### Step 1: Define the Service

Edit `nginx/conf.d/upstreams.conf` and add:

```nginx
upstream SERVICE_NAME {
    least_conn;
    keepalive 32;
    keepalive_timeout 60s;
    server SERVICE_HOST:PORT max_fails=3 fail_timeout=30s;
}
```

**Example:**
```nginx
upstream users_service {
    least_conn;
    keepalive 32;
    keepalive_timeout 60s;
    server users-api:8080 max_fails=3 fail_timeout=30s;
    server users-api-2:8080 max_fails=3 fail_timeout=30s;  # Multiple instances for load balancing
}
```

### Step 2: Add Route

Edit `nginx/conf.d/gateway.conf` and add:

```nginx
location /api/v1/PATH {
    set $route_name "ROUTE_NAME";
    access_by_lua_file /etc/nginx/lua/rate_limiter.lua;
    rewrite_by_lua_file /etc/nginx/lua/circuit_breaker.lua;
    proxy_pass http://SERVICE_NAME;
    include /etc/nginx/conf.d/proxy_params.conf;
    proxy_intercept_errors on;
    error_page 502 503 504 = @circuit_open;
}
```

**Example:**
```nginx
location /api/v1/users {
    set $route_name "users";
    access_by_lua_file /etc/nginx/lua/rate_limiter.lua;
    rewrite_by_lua_file /etc/nginx/lua/circuit_breaker.lua;
    proxy_pass http://users_service;
    include /etc/nginx/conf.d/proxy_params.conf;
    proxy_intercept_errors on;
    error_page 502 503 504 = @circuit_open;
}
```

### Step 3: Reload

```bash
docker-compose restart gateway
```

## Routing

The gateway runs on a single domain (e.g. `example.com`) and routes requests to different backend services based on the URL path.

```
                        ----> users-api    (server 1)
                        |
Client -> example.com ------> products-api (server 2)
                        |
                        ----> orders-api   (server 3)


https://example.com/users      → Users service
https://example.com/products   → Products service
https://example.com/orders     → Orders service
```

## Configuration

### Environment Variables

Edit `docker-compose.yml` environment variables:

```yaml
environment:
  - RATE_LIMIT_RPM=100          # Requests per minute per client
  - RATE_LIMIT_BURST=20         # Burst capacity
  - CB_FAILURE_THRESHOLD=5      # Circuit opens after N failures
  - CB_SUCCESS_THRESHOLD=2      # Circuit closes after N successes
  - CB_TIMEOUT=30               # Seconds before retry
  - CB_WINDOW=60                # Failure window (seconds)
```

### Rate Limiting

- Token bucket algorithm
- Per-client limiting (by IP or `X-Api-Key` header)
- Returns `429` with `Retry-After` header when exceeded

### Circuit Breaker

- **CLOSED**: Normal operation
- **OPEN**: Fast-fail for N seconds after failures
- **HALF_OPEN**: Testing recovery
- Returns `503` when circuit is open.

## Production Notes

### Use Real Certificates

```bash
# Place certificates
cp your-cert.crt certs/server.crt
cp your-key.key certs/server.key

# Enable in docker-compose.yml
volumes:
  - ./certs:/etc/nginx/certs:ro
```

### Monitoring & Observability

The gateway **exposes** metrics and logs - you need to collect them.

#### Metrics (Prometheus + Grafana)

Gateway exposes metrics at `/metrics` endpoint. Set up Prometheus to scrape and add Grafana for visualization.

#### Logs (Loki)

Gateway writes JSON logs to `logs/access.log`.
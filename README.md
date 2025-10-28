API gateway using nginx + Lua. Simple and fast with essentials only.

## Scope

1. **Entry Point** - Single access point for all traffic
2. **Routing** - Path-based routing to the appropriate service
3. **Security** - TLS termination, security headers
4. **Protection** - Rate limiting + circuit breaker
5. **Observability** - JSON logs + Prometheus metrics

## Quick Start

```bash
# 1. Copy environment template (optional - has defaults)
cp .env.example .env

# 2. Start gateway and backend services
docker compose up -d

# 3. Wait for services to be healthy (5-10 seconds)
docker compose ps

# 4. Test health endpoint
curl http://localhost/health

# 5. Test an API endpoint
curl -k https://localhost/api/v1/market

# 6. View metrics (from inside container or internal network only)
docker exec api-gateway curl -s http://localhost/metrics
```

**Note**: The gateway redirects HTTP to HTTPS. Use `-k` flag with curl to accept self-signed certificates in development.

## Testing

### Test All Endpoints

```bash
# Health check
curl http://localhost/health

# Market service
curl -k https://localhost/api/v1/market

# Orders service
curl -k https://localhost/api/v1/orders

# Portfolio service
curl -k https://localhost/api/v1/portfolio
```

### Test Rate Limiting

The gateway has a default limit of 100 requests per minute with a burst capacity of 20 requests.

```bash
# Send 25 rapid requests - first 20 succeed, last 5 are rate limited
for i in {1..25}; do
  curl -s -k -o /dev/null -w "%{http_code} " https://localhost/api/v1/market
done
echo ""

# Expected output: 200 200 200... (20 times) then 429 429 429... (5 times)
```

Rate limited requests return HTTP 429 with retry information:
```bash
curl -k https://localhost/api/v1/market
# Returns: {"error":"Rate limit exceeded","code":"RATE_LIMITED","retry_after":3}
```

**Headers returned:**
- `X-RateLimit-Limit`: Total requests allowed per minute
- `X-RateLimit-Remaining`: Requests remaining in current window
- `Retry-After`: Seconds to wait before retrying (on 429 only)

### Test Circuit Breaker

The circuit breaker protects backend services by failing fast when they're unhealthy.

**Step 1: Trigger circuit breaker by stopping a backend service**
```bash
# Stop market service instances to simulate failure
docker stop market-service market-service-2

# Send 6 requests - circuit opens after 5 failures (CB_FAILURE_THRESHOLD=5)
for i in {1..6}; do
  curl -s -k https://localhost/api/v1/market | jq -r '.error // .code // "success"'
done

# Expected: First 5 show timeout/error, 6th shows "CIRCUIT_OPEN"
```

**Step 2: Verify circuit is open**
```bash
# This returns immediately with 503 (no backend delay)
time curl -k https://localhost/api/v1/market
# Response: {"error":"Service temporarily unavailable","code":"CIRCUIT_OPEN","retry_after":30}
```

**Step 3: Test recovery**
```bash
# Restart services
docker start market-service market-service-2

# Wait for circuit breaker timeout (CB_TIMEOUT=30 seconds)
sleep 30

# Circuit moves to HALF_OPEN - send 2 successful requests to close it
curl -k https://localhost/api/v1/market
curl -k https://localhost/api/v1/market

# Circuit is now CLOSED - normal operation resumes
```

**Circuit Breaker States:**
- `CLOSED`: Normal operation, requests pass through
- `OPEN`: Fast-fail for CB_TIMEOUT seconds (default: 30s)
- `HALF_OPEN`: Testing recovery, limited requests allowed

### View Metrics

Metrics are exposed in Prometheus format at `/metrics` endpoint (internal access only).

```bash
# From inside the container
docker exec api-gateway curl -s http://localhost/metrics

# Or from host machine (works because you're on internal network)
curl -k https://localhost/metrics
```

## Adding a New Service

To add a new service, follow these steps:

### Step 1: Define the Service

Edit `nginx/conf.d/upstreams.conf` and add:

```nginx
upstream SERVICE_NAME {
    least_conn;
    keepalive 32;
    keepalive_requests 100;
    server SERVICE_HOST:PORT max_fails=3 fail_timeout=30s;
}
```

**Example:**
```nginx
upstream users_service {
    least_conn;
    keepalive 32;
    keepalive_requests 100;
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
    log_by_lua_file /etc/nginx/lua/circuit_breaker_log.lua;
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
    log_by_lua_file /etc/nginx/lua/circuit_breaker_log.lua;
    proxy_pass http://users_service;
    include /etc/nginx/conf.d/proxy_params.conf;
    proxy_intercept_errors on;
    error_page 502 503 504 = @circuit_open;
}
```

### Step 3: Rebuild and Restart

```bash
docker compose restart gateway
```

## Routing

The gateway runs on a single domain (e.g. `example.com`) and routes requests to different backend services based on the URL path.

```
                        ----> market-service    (2 servers)
                        |
Client -> example.com ------> order-service     (2 servers)
                        |
                        ----> portfolio-service (1 server)


https://example.com/api/v1/market     ->  market service
https://example.com/api/v1/orders     ->  order service
https://example.com/api/v1/portfolio  ->  portfolio service
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

## Production Deployment

### TLS Certificates

The gateway includes self-signed certificates for development. **Replace these with real certificates in production.**

#### Development (Self-Signed Certificates)

Self-signed certificates are automatically generated during Docker build. These work fine for local development but will show browser warnings.

```bash
# Already included - no action needed
# Certificates are at: /etc/nginx/certs/server.{crt,key}
```

Use the `-k` flag with curl to skip certificate verification:
```bash
curl -k https://localhost/api/v1/market
```

#### Production (Real Certificates)

**Option 1: Use Let's Encrypt (Recommended)**

```bash
# Install certbot
sudo apt-get install certbot

# Get certificates (requires DNS pointing to your server)
sudo certbot certonly --standalone -d yourdomain.com -d api.yourdomain.com

# Copy certificates to project
sudo cp /etc/letsencrypt/live/yourdomain.com/fullchain.pem certs/server.crt
sudo cp /etc/letsencrypt/live/yourdomain.com/privkey.pem certs/server.key
sudo chmod 644 certs/server.crt
sudo chmod 600 certs/server.key

# Restart gateway
docker compose restart gateway
```

**Option 2: Use Your Own Certificates**

```bash
# Place your certificates in the certs directory
cp your-certificate.crt certs/server.crt
cp your-private-key.key certs/server.key

# Set proper permissions
chmod 644 certs/server.crt
chmod 600 certs/server.key

# Update docker-compose.yml to mount real certificates
volumes:
  - ./certs:/etc/nginx/certs:ro

# Restart gateway
docker compose restart gateway
```

**Option 3: Enable OCSP Stapling (for CA-signed certificates)**

Once you have valid CA-signed certificates, enable OCSP stapling for better performance:

Edit `nginx/conf.d/gateway.conf` and uncomment:
```nginx
# Uncomment these lines:
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
```

**Certificate Renewal**

Set up automatic renewal with certbot:
```bash
# Add cron job for renewal
sudo crontab -e

# Add this line to check daily and renew if needed:
0 2 * * * certbot renew --quiet --deploy-hook "docker compose -f /path/to/project/docker-compose.yml restart gateway"
```

### Monitoring & Observability

The gateway **exposes** metrics and logs - you need to collect them with external tools. You need to configure prometheus to scrape the gateway metrics, setup grafana to visualize and loki for log collection.

## Troubleshooting

### Gateway Won't Start

```bash
# Check logs for errors
docker logs api-gateway

# Check configuration syntax
docker exec api-gateway openresty -t

# Verify all services are running
docker compose ps
```

### Certificate Errors

```bash
# Development: Use -k flag to ignore self-signed cert warnings
curl -k https://localhost/api/v1/market

# Production: Verify certificate paths
docker exec api-gateway ls -la /etc/nginx/certs/

# Check certificate expiration
openssl x509 -in certs/server.crt -noout -dates
```

### Rate Limiting Not Working

```bash
# Check metrics to see if rate limiting is active
docker exec api-gateway curl -s http://localhost/metrics | grep rate_limited

# Verify environment variables are set
docker exec api-gateway env | grep RATE_LIMIT

# Check logs for rate limit events
docker exec api-gateway grep "429" /var/log/nginx/access.log | tail -5
```

### Circuit Breaker Not Triggering

```bash
# Check circuit breaker state in metrics
docker exec api-gateway curl -s http://localhost/metrics | grep circuit

# Verify backend service is actually failing
docker logs market-service

# Check environment variables
docker exec api-gateway env | grep CB_
```

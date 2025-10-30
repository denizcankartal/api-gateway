API gateway using Traefik.

## Scope

1. **Entry Point** - Single access point for all traffic
2. **Routing** - Path-based routing to the appropriate service
3. **Security** - TLS termination, security headers
4. **Protection** - Rate limiting + circuit breaker
5. **Observability** - JSON logs + Prometheus metrics + Dashboard

## Quick Start

```bash
# 1. Generate TLS certificates
./generate-certs.sh

# 2. Start gateway and backend services
docker compose up -d

# 3. Wait for services to be healthy (5-10 seconds)
docker compose ps

# 4. Test health endpoint
curl http://localhost/health

# 5. Test an API endpoint
curl -k https://localhost/api/v1/market

# 6. View Traefik dashboard
curl http://localhost:8080/dashboard/

# 7. View metrics
curl http://localhost:8080/metrics
```

**Note**: The gateway redirects HTTP to HTTPS. Use `-k` flag with curl to accept self-signed certificates in development.

## Traefik Dashboard

Traefik includes a real-time web dashboard at `http://localhost:8080/dashboard/`:

- **HTTP Routers**: View all routes and their rules
- **HTTP Services**: See backend service status and health
- **HTTP Middlewares**: Inspect middleware chains (rate limiting, circuit breaker, etc.)
- **Entrypoints**: Monitor traffic on ports 80, 443, 8080

The dashboard shows live request statistics, service health, and configuration.

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

Traefik's rate limiting is configured per route: 100 requests per minute with a burst capacity of 20 requests.

```bash
# Send 25 rapid requests - first 20 succeed, last 5 are rate limited
for i in {1..25}; do
  curl -s -k -o /dev/null -w "%{http_code} " https://localhost/api/v1/market
done
echo ""

# Expected output: 200 200 200... (20 times) then 429 429 429... (5 times)
```

Rate limited requests return HTTP 429:
```bash
curl -k https://localhost/api/v1/market
# Returns: 429 Too Many Requests
```

**Headers returned:**
- `X-RateLimit-Limit`: Total requests allowed per period
- `X-RateLimit-Remaining`: Requests remaining in current window
- `X-RateLimit-Reset`: Unix timestamp when limit resets

### Test Circuit Breaker

The circuit breaker protects backend services by failing fast when they're unhealthy.

**Step 1: Trigger circuit breaker by stopping a backend service**
```bash
# Stop market service instances to simulate failure
docker stop market-service market-service-2

# Send multiple requests - circuit opens after detecting high error rate
for i in {1..10}; do
  curl -s -k -o /dev/null -w "%{http_code} " https://localhost/api/v1/market
done
echo ""

# Expected: 502/503/504 errors, then circuit opens and returns 503 immediately
```

**Step 2: Verify circuit is open**
```bash
# This returns immediately with 503 (no backend delay)
time curl -k https://localhost/api/v1/market
# Response: 503 Service Unavailable
```

**Step 3: Test recovery**
```bash
# Restart services
docker start market-service market-service-2

# Wait for circuit breaker timeout (fallbackDuration: 30 seconds)
sleep 30

# Send requests - circuit moves to half-open state
curl -k https://localhost/api/v1/market
curl -k https://localhost/api/v1/market

# After successful requests, circuit closes and normal operation resumes
```

**Circuit Breaker Expression:**
```yaml
expression: "NetworkErrorRatio() > 0.5 || ResponseCodeRatio(500, 600, 0, 600) > 0.3"
```
- Opens if >50% network errors OR >30% 5xx responses
- Stays open for 30 seconds (fallbackDuration)
- Half-open recovery period: 10 seconds

### View Metrics

Metrics are exposed in Prometheus format at `http://localhost:8080/metrics`:

```bash
# View all metrics
curl -s http://localhost:8080/metrics

# Filter for rate limiting metrics
curl -s http://localhost:8080/metrics | grep traefik_service_requests_total

# Filter for circuit breaker metrics
curl -s http://localhost:8080/metrics | grep traefik_service_open_connections
```

**Key Metrics:**
- `traefik_service_requests_total` - Total requests per service
- `traefik_service_request_duration_seconds` - Request latency histogram
- `traefik_entrypoint_requests_total` - Requests per entrypoint
- `traefik_router_requests_total` - Requests per router

## Adding a New Service

### Step 1: Add Middleware Chain

Edit `traefik/config/dynamic/middlewares.yml`:

```yaml
http:
  middlewares:
    # Add rate limiting for your service
    rate-limit-SERVICENAME:
      rateLimit:
        average: 100
        period: 1m
        burst: 20
        sourceCriterion:
          requestHeaderName: X-Api-Key

    # Add circuit breaker for your service
    circuit-breaker-SERVICENAME:
      circuitBreaker:
        expression: "NetworkErrorRatio() > 0.5 || ResponseCodeRatio(500, 600, 0, 600) > 0.3"
        checkPeriod: 60s
        fallbackDuration: 30s
        recoveryDuration: 10s

    # Create middleware chain
    SERVICENAME-chain:
      chain:
        middlewares:
          - rate-limit-SERVICENAME
          - circuit-breaker-SERVICENAME
          - security-headers
          - compression
          - retry
          - request-id
```

### Step 2: Add Route and Service

Edit `traefik/config/dynamic/routes.yml`:

```yaml
http:
  routers:
    SERVICENAME-router:
      rule: "PathPrefix(`/api/v1/SERVICENAME`)"
      service: SERVICENAME-service
      middlewares:
        - SERVICENAME-chain
      entryPoints:
        - websecure
      tls: {}

  services:
    SERVICENAME-service:
      loadBalancer:
        healthCheck:
          path: /health
          interval: 10s
          timeout: 3s
        servers:
          - url: "http://servicename:8080"
        passHostHeader: true
```

**Example: Adding a Users Service**

```yaml
# In middlewares.yml
http:
  middlewares:
    rate-limit-users:
      rateLimit:
        average: 100
        period: 1m
        burst: 20
        sourceCriterion:
          requestHeaderName: X-Api-Key

    circuit-breaker-users:
      circuitBreaker:
        expression: "NetworkErrorRatio() > 0.5 || ResponseCodeRatio(500, 600, 0, 600) > 0.3"
        checkPeriod: 60s
        fallbackDuration: 30s
        recoveryDuration: 10s

    users-chain:
      chain:
        middlewares:
          - rate-limit-users
          - circuit-breaker-users
          - security-headers
          - compression
          - retry
          - request-id
```

```yaml
# In routes.yml
http:
  routers:
    users-router:
      rule: "PathPrefix(`/api/v1/users`)"
      service: users-service
      middlewares:
        - users-chain
      entryPoints:
        - websecure
      tls: {}

  services:
    users-service:
      loadBalancer:
        healthCheck:
          path: /health
          interval: 10s
          timeout: 3s
        servers:
          - url: "http://users-api:8080"
          - url: "http://users-api-2:8080"  # Multiple instances
        passHostHeader: true
```

### Step 3: Traefik Auto-Reloads

**No restart needed!** Traefik watches for file changes and reloads automatically.

```bash
# Verify the new route is loaded
curl http://localhost:8080/api/rawdata | jq '.http.routers | keys'

# Test the new service
curl -k https://localhost/api/v1/users
```

## Routing

The gateway runs on a single domain and routes requests to different backend services based on the URL path.

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

**Note:** All configuration is in YAML files. No environment variables needed (unlike nginx+lua implementation).

### Rate Limiting

Edit `traefik/config/dynamic.yml`:

```yaml
http:
  middlewares:
    rate-limit:
      rateLimit:
        average: 100      # Requests per period
        period: 1m        # Time period (1m, 1h, etc.)
        burst: 20         # Extra requests allowed in burst
```

**By default, rate limiting is per IP address.** Each IP gets 100 requests/minute.

#### Rate Limiting by API Key (Optional)

If you want **per-user rate limiting** instead of per-IP:

```yaml
http:
  middlewares:
    rate-limit:
      rateLimit:
        average: 100
        period: 1m
        burst: 20
        sourceCriterion:
          requestHeaderName: X-Api-Key  # Rate limit per API key
```

**How it works:**
- Clients send an API key header with each request:
  ```bash
  curl -H "X-Api-Key: user-123" https://api.example.com/market
  curl -H "X-Api-Key: user-456" https://api.example.com/market
  ```
- Each unique `X-Api-Key` value gets its own rate limit bucket
- `user-123` gets 100 req/min, `user-456` gets their own 100 req/min
- If no header is sent, falls back to IP-based rate limiting

**Use cases:**
- **IP-based (default)**: Good for public APIs, prevents single machine abuse
- **Header-based**: Good for authenticated APIs, per-user quotas, SaaS pricing tiers

**Configuration options:**
- `average`: Number of requests allowed per period
- `period`: Time period (`1s`, `1m`, `1h`, `24h`)
- `burst`: Extra requests allowed in burst (like a token bucket)
- `sourceCriterion.requestHeaderName`: Header to use for client identification (default: IP address)

### Circuit Breaker

Edit `traefik/config/dynamic/middlewares.yml`:

```yaml
http:
  middlewares:
    circuit-breaker-market:
      circuitBreaker:
        expression: "NetworkErrorRatio() > 0.5 || ResponseCodeRatio(500, 600, 0, 600) > 0.3"
        checkPeriod: 60s          # How long to track errors
        fallbackDuration: 30s     # How long circuit stays open
        recoveryDuration: 10s     # Half-open recovery period
```

**Expression Functions:**
- `NetworkErrorRatio()` - Ratio of network errors (0.0 to 1.0)
- `ResponseCodeRatio(from, to, dividedByFrom, dividedByTo)` - Ratio of status codes
- `LatencyAtQuantileMS(quantile)` - Latency at percentile

**Examples:**
```yaml
# Open on >50% errors
expression: "NetworkErrorRatio() > 0.5"

# Open on >30% 5xx responses
expression: "ResponseCodeRatio(500, 600, 0, 600) > 0.3"

# Open on high latency
expression: "LatencyAtQuantileMS(50.0) > 1000"

# Combine conditions
expression: "NetworkErrorRatio() > 0.5 || ResponseCodeRatio(500, 600, 0, 600) > 0.3"
```

### Load Balancing

**Traefik automatically load balances** when you define multiple servers for a service.

Edit `traefik/config/dynamic.yml`:

```yaml
http:
  services:
    market-service:
      loadBalancer:
        servers:
          - url: "http://market-service:8080"    # Instance 1
          - url: "http://market-service-2:8080"  # Instance 2
          - url: "http://market-service-3:8080"  # Instance 3 (add as many as needed)
```

**How it works:**
- Traefik distributes traffic across all healthy servers
- Default algorithm: **Round Robin** (Request 1 → Server 1, Request 2 → Server 2, etc.)
- Unhealthy servers are automatically removed from rotation
- No additional configuration needed

**Load Balancing Algorithms:**

Traefik supports different algorithms (Round Robin is default):

```yaml
# Round Robin (default) - equal distribution
market-service:
  loadBalancer:
    servers:
      - url: "http://server1:8080"
      - url: "http://server2:8080"

# Weighted Round Robin - send more traffic to powerful servers
market-service:
  loadBalancer:
    servers:
      - url: "http://server1:8080"
        weight: 3  # Gets 3x more traffic
      - url: "http://server2:8080"
        weight: 1  # Gets 1x traffic

# Sticky sessions - same client → same server
market-service:
  loadBalancer:
    servers:
      - url: "http://server1:8080"
      - url: "http://server2:8080"
    sticky:
      cookie:
        name: "server_id"
        httpOnly: true
```

**Health Checks:**

Add health checks to automatically remove unhealthy servers:

```yaml
market-service:
  loadBalancer:
    healthCheck:
      path: /health
      interval: 10s
      timeout: 3s
    servers:
      - url: "http://market-service:8080"
      - url: "http://market-service-2:8080"
```

### Security Headers

Edit `traefik/config/dynamic.yml`:

```yaml
http:
  middlewares:
    security-headers:
      headers:
        customResponseHeaders:
          X-Frame-Options: "SAMEORIGIN"
          X-Content-Type-Options: "nosniff"
          X-XSS-Protection: "1; mode=block"
          Strict-Transport-Security: "max-age=31536000; includeSubDomains"
```

### TLS Configuration

Edit `traefik/config/dynamic/routes.yml`:

```yaml
tls:
  options:
    default:
      minVersion: VersionTLS12  # TLS 1.2 and 1.3
      cipherSuites:
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        # Add more cipher suites as needed

  certificates:
    - certFile: /etc/traefik/certs/server.crt
      keyFile: /etc/traefik/certs/server.key
```

## Production Deployment

### TLS Certificates

You have **three options** for TLS certificates:

#### Option 1: Development (Self-Signed) - DEFAULT

For local testing only. Browsers will show security warnings.

```bash
# Generate certificates (already done if you followed Quick Start)
./generate-certs.sh

# Test with curl (use -k to skip certificate verification)
curl -k https://localhost/api/v1/market
```

**What generate-certs.sh does:**
- Creates a self-signed certificate valid for 365 days
- Adds localhost, api-gateway, and 127.0.0.1 as valid domains
- Saves to `traefik/certs/server.crt` and `traefik/certs/server.key`

#### Option 2: Production with Let's Encrypt (Automatic)

**Best for production** - Free, automatic renewal, no manual work.

**Requirements:**
- Domain name pointing to your server (e.g., api.example.com)
- Port 80 accessible from internet (for Let's Encrypt verification)

**Setup:**

1. Edit `traefik/config/traefik.yml` - add certificate resolver:

```yaml
# Add this section to traefik.yml
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@yourdomain.com  # Let's Encrypt notifications
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
```

2. Update `docker-compose.yml` - add volume for certificate storage:

```yaml
volumes:
  - ./traefik/config/traefik.yml:/etc/traefik/traefik.yml:ro
  - ./traefik/config/dynamic.yml:/etc/traefik/dynamic.yml:ro
  - ./traefik/certs:/etc/traefik/certs:ro
  - ./logs:/var/log/traefik
  - /var/run/docker.sock:/var/run/docker.sock:ro
  - ./letsencrypt:/etc/traefik/letsencrypt  # Add this line
```

3. Create directory and file:

```bash
mkdir letsencrypt
touch letsencrypt/acme.json
chmod 600 letsencrypt/acme.json
```

4. Edit `traefik/config/dynamic.yml` - update routers to use your domain:

```yaml
http:
  routers:
    market-router:
      rule: "Host(`api.yourdomain.com`) && PathPrefix(`/api/v1/market`)"
      service: market-service
      middlewares:
        - rate-limit
        - circuit-breaker
        - security-headers
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt  # Add this
```

5. Restart and test:

```bash
docker compose restart gateway

# Certificate is fetched automatically on first request
curl https://api.yourdomain.com/api/v1/market
```

**That's it!** Traefik automatically:
- Requests certificates from Let's Encrypt
- Renews certificates before expiration (no cron jobs needed)
- Stores certificates in `letsencrypt/acme.json`

#### Option 3: Production with Your Own Certificates

If you already have certificates from your organization or purchased from a CA.

```bash
# 1. Copy your certificates to the certs directory
cp /path/to/your-certificate.crt traefik/certs/server.crt
cp /path/to/your-private-key.key traefik/certs/server.key

# 2. Set proper permissions
chmod 644 traefik/certs/server.crt
chmod 600 traefik/certs/server.key

# 3. Restart gateway
docker compose restart gateway

# 4. Test
curl https://yourdomain.com/api/v1/market
```

**Certificate renewal:**
- Replace files when certificates expire
- Restart gateway: `docker compose restart gateway`
- Consider automating with a script if your CA provides an API

### Monitoring & Observability

Traefik provides built-in observability:

1. **Dashboard**: Real-time UI at `http://localhost:8080/dashboard/`
2. **Prometheus Metrics**: Scraped from `http://localhost:8080/metrics`
3. **Access Logs**: JSON format in `./logs/access.log`
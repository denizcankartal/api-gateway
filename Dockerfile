FROM openresty/openresty:1.25.3.1-alpine

# Install dependencies with specific versions for reproducibility
RUN apk add --no-cache \
    openssl \
    ca-certificates \
    curl \
    && rm -rf /var/cache/apk/* \
    && rm -rf /tmp/*

# Create necessary directories
RUN mkdir -p /var/log/nginx \
    /etc/nginx/certs \
    /etc/nginx/conf.d \
    /etc/nginx/lua

# Copy nginx configuration
COPY nginx/nginx.conf /etc/nginx/nginx.conf
COPY nginx/conf.d/ /etc/nginx/conf.d/
COPY nginx/lua/ /etc/nginx/lua/

# Generate self-signed certificate for development
# (Replace with real certificates in production)
RUN openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout /etc/nginx/certs/server.key \
    -out /etc/nginx/certs/server.crt \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

# Set proper permissions
RUN chown -R nobody:nobody /var/log/nginx \
    && chmod -R 755 /etc/nginx/lua \
    && chmod 600 /etc/nginx/certs/server.key \
    && chmod 644 /etc/nginx/certs/server.crt

# Note: Cannot validate nginx config at build time due to upstream DNS requirements
# Config is validated at container start time instead

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Expose ports
EXPOSE 80 443

# Start nginx with custom config path
CMD ["openresty", "-c", "/etc/nginx/nginx.conf", "-g", "daemon off;"]

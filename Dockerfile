FROM openresty/openresty:1.25.3.1-alpine

# Install dependencies
RUN apk add --no-cache \
    openssl \
    ca-certificates \
    curl \
    && rm -rf /var/cache/apk/*

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

# Set permissions
RUN chown -R nobody:nobody /var/log/nginx \
    && chmod -R 755 /etc/nginx/lua

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

# Expose ports
EXPOSE 80 443

# Start nginx
CMD ["openresty", "-g", "daemon off;"]

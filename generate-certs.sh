#!/bin/bash

# Generate self-signed TLS certificates for development
# Production: Replace with Let's Encrypt or proper CA-signed certificates

set -e

CERT_DIR="./traefik/certs"
CERT_FILE="$CERT_DIR/server.crt"
KEY_FILE="$CERT_DIR/server.key"

# Create certs directory if it doesn't exist
mkdir -p "$CERT_DIR"

# Check if certificates already exist
if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
    echo "Certificates already exist at $CERT_DIR"
    echo "To regenerate, delete them first: rm $CERT_DIR/server.*"
    exit 0
fi

echo "Generating self-signed TLS certificate..."

# Generate self-signed certificate (valid for 365 days)
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,DNS:api-gateway,IP:127.0.0.1"

echo "Certificate generated successfully!"
echo "  Certificate: $CERT_FILE"
echo "  Private Key: $KEY_FILE"
echo ""
echo "Note: This is a self-signed certificate for development only."
echo "For production, use Let's Encrypt or a proper CA-signed certificate."

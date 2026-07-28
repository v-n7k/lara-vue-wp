#!/bin/bash
# Run this on your VPS host machine in the same directory as docker-compose.yml

VHOSTS_CONF="./configs/nginx/conf.d/vhosts.conf"
AUTH_FILE="./auth/.htpasswd"

echo "Initializing proxy generation sequence..."

# 1. Safely load variables directly from .env (Best Practice for secrets)
if [ -f ".env" ]; then
    set -a
    . .env
    set +a
fi

NGINX_CONTAINER="${PRODUCT_NAME:-vps}-nginx"

# 2. Generate the Basic Auth file if credentials exist
if [ -n "$BASIC_AUTH_USER" ] && [ -n "$BASIC_AUTH_PASSWORD" ]; then
    echo " -> Generating .htpasswd for user: $BASIC_AUTH_USER"

    # Use OpenSSL (natively available on the Linux host) to generate the hash
    # -apr1 creates an MD5-based password hash compatible with NGINX auth_basic
    HASH=$(openssl passwd -apr1 "$BASIC_AUTH_PASSWORD")

    # Write the user and hash to the file
    echo "$BASIC_AUTH_USER:$HASH" > "$AUTH_FILE"
else
    echo " -> Warning: BASIC_AUTH_USER or BASIC_AUTH_PASSWORD missing from .env. Skipping .htpasswd generation."
fi

echo " -> Generating NGINX configuration from Docker Compose labels..."

# 3. Parse Docker Compose and dynamically map endpoints
: > "$VHOSTS_CONF" # Truncate vhosts
docker compose config --format json | jq -r '
  .services | to_entries[] |
  select(.value.hostname != null and .value.domainname != null) |
  "\(.key)|\(.value.hostname)|\(.value.domainname)|\((.value.labels // {})["nginx.schema"] // "http")|\((.value.labels // {})["nginx.port"] // "80")|\((.value.labels // {})["nginx.auth"] // "false")"
' | while IFS="|" read -r svc hostname domainname schema port auth; do

    # www hosts also answer for the bare (apex) domain
    SERVER_NAME="${hostname}.${domainname}"
    if [ "$hostname" = "www" ]; then
        SERVER_NAME="${SERVER_NAME} ${domainname}"
    fi

    echo " -> Mapping vhost: ${SERVER_NAME} to ${schema}://${svc}:${port} (Auth: ${auth})"

    # Generate optional Basic Auth block
    AUTH_CONF=""
    if [ "$auth" = "true" ]; then
        AUTH_CONF="
            auth_basic \"Restricted Access\";
            auth_basic_user_file /etc/nginx/auth/.htpasswd;"
    fi

    # Append the server block
    cat << EOF >> "$VHOSTS_CONF"
    server {
        listen 443 ssl;
        server_name ${SERVER_NAME};

        location / {
            proxy_pass ${schema}://${svc}:${port};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;${AUTH_CONF}
        }
    }

EOF
done

echo "NGINX configuration generated successfully."

# 4. Gracefully reload NGINX if the container is already running
if docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    echo " -> Validating NGINX configuration..."
    if docker exec "$NGINX_CONTAINER" nginx -t; then
        echo " -> Reloading NGINX container without dropping connections..."
        docker exec "$NGINX_CONTAINER" nginx -s reload
    else
        echo " -> ERROR: nginx config test failed — reload skipped, old config still active." >&2
    fi
fi

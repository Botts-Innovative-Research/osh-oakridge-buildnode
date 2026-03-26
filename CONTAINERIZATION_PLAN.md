# CONTAINERIZATION_PLAN.md - OSCAR Full Stack Containerization

This document outlines the proposal for migrating the OSCAR (Open Source Central Alarm Station) architecture to a fully containerized deployment model orchestrated by Docker Compose.

## 1. Proposed `docker-compose.yml`

The new `docker-compose.yml` will unify the PostGIS database, the OSH Backend, and the Caddy Reverse Proxy into a single orchestration unit.

### 1.1 Service Definitions

```yaml
services:
  osh-postgis:
    build:
      context: ./dist/release/postgis
      dockerfile: Dockerfile
    image: oscar-postgis:latest
    container_name: oscar-postgis-container
    environment:
      - POSTGRES_DB=gis
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
      # Performance Tuning from .env
      - POSTGRES_SHARED_BUFFERS=${DB_SHARED_BUFFERS:-128MB}
      - POSTGRES_EFFECTIVE_CACHE_SIZE=${DB_EFFECTIVE_CACHE_SIZE:-512MB}
      - POSTGRES_WORK_MEM=${DB_WORK_MEM:-4MB}
      - POSTGRES_MAX_WAL_SIZE=${DB_MAX_WAL_SIZE:-1GB}
      - POSTGRES_MAX_CONNECTIONS=${DB_MAX_CONNECTIONS:-50}
      - POSTGRES_MAINTENANCE_WORK_MEM=${DB_MAINTENANCE_WORK_MEM:-64MB}
    ports:
      - "5432:5432"
    volumes:
      - ./pgdata:/var/lib/postgresql/data
    secrets:
      - db_password
    networks:
      - osh-internal
    deploy:
      resources:
        limits:
          memory: ${DB_MEM_LIMIT:-1G}
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d gis"]
      interval: 10s
      timeout: 5s
      retries: 5

  osh-backend:
    build:
      context: .
      dockerfile: Dockerfile.osh
    image: oscar-backend:latest
    container_name: oscar-backend-container
    environment:
      - DB_HOST=${DB_HOST:-osh-postgis}
      - POSTGRES_PASSWORD_FILE=/run/secrets/db_password
      - KEYSTORE=./osh-keystore.p12
      - KEYSTORE_TYPE=PKCS12
      - TRUSTSTORE=./truststore.jks
      - TRUSTSTORE_TYPE=JKS
      - SHOW_CMD=true
      # JVM Tuning from .env
      - JAVA_OPTS=-Xmx${BACKEND_MEM_LIMIT:-2G} -Xms${BACKEND_MEM_LIMIT:-2G}
    volumes:
      - ./osh-node-oscar/config:/app/config
      - ./osh-node-oscar/db:/app/db
      - ./osh-node-oscar/files:/app/files
      - ./osh-node-oscar/osh-keystore.p12:/app/osh-keystore.p12
      - ./osh-node-oscar/.app_secrets:/app/.app_secrets
      - ./osh-node-oscar/truststore.jks:/app/truststore.jks
    secrets:
      - db_password
    networks:
      - osh-internal
    depends_on:
      osh-postgis:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: ${BACKEND_MEM_LIMIT:-2G}
    restart: unless-stopped
    # Port 8282 is not exposed to the host network to ensure it's only accessible via the proxy
    # For local debugging, it can be bound to 127.0.0.1:8282
    ports:
      - "127.0.0.1:8282:8282"

  osh-proxy:
    image: caddy:2-alpine
    container_name: oscar-proxy-container
    environment:
      - TAILSCALE_DOMAIN=${TAILSCALE_DOMAIN:-}
      - LOCAL_DOMAIN=${LOCAL_DOMAIN:-localhost}
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy:/etc/caddy
      - caddy_data:/data
      - caddy_config:/config
      - /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock
      - ./osh-node-oscar/osh-leaf.crt:/etc/caddy/certs/osh-leaf.crt:ro
      - ./osh-node-oscar/osh-leaf.key:/etc/caddy/certs/osh-leaf.key:ro
    networks:
      - osh-internal
    restart: unless-stopped

networks:
  osh-internal:
    driver: bridge

secrets:
  db_password:
    file: .db_password

volumes:
  caddy_data:
  caddy_config:
```

### 1.2 Internal Network Routing and Port Mappings
- **Isolation**: All services reside on the `osh-internal` bridge network.
- **osh-postgis**: Port 5432 is internal only.
- **osh-backend**: Port 8282 is bound specifically to `127.0.0.1` on the host, preventing external access except through the reverse proxy. Within the Docker network, it is reachable by `osh-proxy` at `http://osh-backend:8282`.
- **osh-proxy**: Ports 80 and 443 are exposed to the host for public/LAN access.

## 2. Proposed TLS & Routing Strategy (Caddy Dynamic Switching)

The Caddy reverse proxy will handle TLS termination and dynamic routing based on environment variables.

### 2.1 Caddyfile Structure

The Caddyfile will implement a "Dual-Listener" setup, ensuring the local LAN fallback is always active even if Tailscale is enabled.

**Main Caddyfile (`/etc/caddy/Caddyfile`):**
```caddy
{
    # Global options
}

# 1. Local LAN Block (Always Active Fallback)
{$LOCAL_DOMAIN:localhost}, 127.0.0.1 {
    # Forward headers to the backend
    reverse_proxy https://osh-backend:8282 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        transport http {
            tls_insecure_skip_verify
        }
    }

    # Use local Java certificates for LAN encryption
    tls /etc/caddy/certs/osh-leaf.crt /etc/caddy/certs/osh-leaf.key
}

# 2. Tailscale Block (Conditional Federated Access)
{$TAILSCALE_DOMAIN} {
    @has_tailscale expression "{env.TAILSCALE_DOMAIN} != ''"
    handle @has_tailscale {
        # Forward headers to the backend
        reverse_proxy https://osh-backend:8282 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            transport http {
                tls_insecure_skip_verify
            }
        }

        # Use Tailscale's automatic TLS
        tls {
            get_certificate tailscale
        }
    }
}
```

### 2.2 Operational Details
- **Dual-Listener Reliability**: Caddy simultaneously serves the local LAN/localhost IP and the Tailscale domain. If Tailscale fails or loses internet connectivity, operators can immediately fall back to the LAN address without restarting services.
- **Local Mode**: Uses the locally generated Java Leaf certificates (`osh-leaf.crt` and `osh-leaf.key`).
- **Federated Mode (Tailscale)**: Uses the `get_certificate tailscale` directive. This block is only active when `TAILSCALE_DOMAIN` is populated.
- **Header Forwarding**: Standard headers (`X-Forwarded-For`, `X-Forwarded-Proto`, etc.) are forwarded to ensure the OSH backend correctly identifies the client's origin.

## 3. Proposed Backend Dockerfile

The OSH Backend will be containerized using a lightweight Alpine-based Java image.

### 3.1 Dockerfile Structure

```dockerfile
# Dockerfile.osh
FROM eclipse-temurin:21-jre-alpine

# Set the working directory
WORKDIR /app

# GLOBAL BUILD CONSTRAINT: Explicitly set the font package to font-freefont
# GLOBAL BUILD CONSTRAINT: Bypass HTTPS for corporate SSL inspection during build
RUN sed -i 's/https/http/g' /etc/apk/repositories && \
    apk update && \
    apk add --no-cache font-freefont openssl bash && \
    rm -rf /var/cache/apk/*

# Copy build artifacts
COPY ./osh-node-oscar/lib /app/lib
COPY ./osh-node-oscar/config /app/config
COPY ./osh-node-oscar/web /app/web
COPY ./osh-node-oscar/logback.xml /app/logback.xml

# The ENTRYPOINT ensures pre-launch checks (Local CA generation and fail-secure secret loading) run before the JVM starts
# JAVA_OPTS is used to pass memory limits from the .env file
ENTRYPOINT ["/bin/bash", "-c", "java -cp 'lib/*' com.botts.impl.security.LocalCAUtility && if [ ! -f .app_secrets ]; then echo 'CRITICAL ERROR: .app_secrets not found. Halting startup.'; exit 1; fi && export KEYSTORE_PASSWORD=$(head -n 1 .app_secrets) && java $JAVA_OPTS -Djavax.net.ssl.keyStorePassword=$KEYSTORE_PASSWORD -Djavax.net.ssl.trustStorePassword=$KEYSTORE_PASSWORD -cp 'lib/*' com.botts.impl.security.SensorHubWrapper ./config/config.json ./db"]
```

## 4. Scaled Deployment Profiles (.env Templates)

These profiles define the environment variables required to scale the system for different hardware scenarios.

### Scenario A: "Edge Node" (1 Lane, All-in-One)
**Hardware**: Raspberry Pi (4GB-8GB RAM)

```ini
DB_HOST=osh-postgis
BACKEND_MEM_LIMIT=2G
DB_MEM_LIMIT=1G
DB_MAX_CONNECTIONS=50
DB_SHARED_BUFFERS=128MB
DB_EFFECTIVE_CACHE_SIZE=512MB
DB_WORK_MEM=4MB
DB_MAX_WAL_SIZE=1GB
```

### Scenario B: "Tactical Hub" (10 Lanes / 20 Cameras, All-in-One)
**Hardware**: Powerful Laptop (16GB RAM)

```ini
DB_HOST=osh-postgis
BACKEND_MEM_LIMIT=8G
DB_MEM_LIMIT=4G
DB_MAX_CONNECTIONS=100
DB_SHARED_BUFFERS=1GB
DB_EFFECTIVE_CACHE_SIZE=3GB
DB_WORK_MEM=16MB
DB_MAX_WAL_SIZE=4GB
```

### Scenario C: "Enterprise Central Hub" (50 Lanes / 100 Cameras, Distributed LAN)
**Hardware**: Machine 1 (App Server, 16GB), Machine 2 (DB Server, 16GB)

**Machine 1 (Application Server) Profile**:
```ini
DB_HOST=<IP_ADDRESS_OF_MACHINE_2>
BACKEND_MEM_LIMIT=14G
# (DB variables omitted/ignored as PostGIS does not run on this machine)
```

**Machine 2 (Database Server) Profile**:
```ini
DB_MEM_LIMIT=14G
DB_MAX_CONNECTIONS=200
DB_SHARED_BUFFERS=4GB
DB_EFFECTIVE_CACHE_SIZE=10GB
DB_MAINTENANCE_WORK_MEM=1GB
DB_WORK_MEM=64MB
DB_MAX_WAL_SIZE=8GB
```

## 5. Global Build Constraint Acknowledgment
- **Font Package**: All Alpine-based Dockerfiles explicitly set the font package to `font-freefont`.
- **HTTP Bypass**: All `apk add` steps use `sed -i 's/https/http/g' /etc/apk/repositories` to ensure reliability behind corporate firewalls.

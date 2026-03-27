FROM postgis/postgis:16-3.4

# Install fonts as required by AI_CONTRIBUTING_RULES.md
RUN apt-get update && apt-get install -y fonts-freefont-ttf && rm -rf /var/lib/apt/lists/*

COPY init-extensions.sql /docker-entrypoint-initdb.d/init-extensions.sql

# Generate self-signed certificate for SSL support
RUN openssl req -new -x509 -days 365 -nodes -text -out /var/lib/postgresql/server.crt \
    -keyout /var/lib/postgresql/server.key -subj "/CN=oscar-postgis" \
    && chmod 600 /var/lib/postgresql/server.key \
    && chown postgres:postgres /var/lib/postgresql/server.key /var/lib/postgresql/server.crt

ENV POSTGRES_INITDB_ARGS="--auth-local=trust --auth-host=scram-sha-256 -c max_parallel_workers_per_gather=0 -c max_parallel_workers=0 -c ssl=on -c ssl_cert_file=/var/lib/postgresql/server.crt -c ssl_key_file=/var/lib/postgresql/server.key"
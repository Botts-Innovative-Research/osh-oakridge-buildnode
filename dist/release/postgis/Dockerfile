FROM postgis/postgis:16-3.5@sha256:19b6ffa248d2f864d29d6c338459f02d63c0d7ce341fa86b3bcba8484a130bff

COPY init-extensions.sql /docker-entrypoint-initdb.d/init-extensions.sql
COPY init-app-role.sh /docker-entrypoint-initdb.d/20-init-app-role.sh

RUN chmod 0555 /docker-entrypoint-initdb.d/20-init-app-role.sh

ENV POSTGRES_INITDB_ARGS="--auth-local=scram-sha-256 --auth-host=scram-sha-256 -c max_parallel_workers_per_gather=0 -c max_parallel_workers=0"

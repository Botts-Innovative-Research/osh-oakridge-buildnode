FROM postgis/postgis:16-3.5@sha256:19b6ffa248d2f864d29d6c338459f02d63c0d7ce341fa86b3bcba8484a130bff

ARG OSCAR_VERSION=local
LABEL org.opencontainers.image.title="OSCAR PostGIS" \
      org.opencontainers.image.version="${OSCAR_VERSION}" \
      com.botts.oscar.storage-profile="${OSCAR_VERSION}"

ENV OSCAR_STORAGE_PROFILE_VERSION="${OSCAR_VERSION}"

COPY init-extensions.sql /docker-entrypoint-initdb.d/init-extensions.sql
COPY init-app-role.sh /docker-entrypoint-initdb.d/20-init-app-role.sh
COPY archive-wal.sh /usr/local/bin/oscar-archive-wal
COPY prepare-restore.sh /usr/local/bin/oscar-prepare-restore
COPY merge-wal-restore.sh /usr/local/bin/oscar-merge-wal-restore

RUN chmod 0555 /docker-entrypoint-initdb.d/20-init-app-role.sh /usr/local/bin/oscar-archive-wal /usr/local/bin/oscar-prepare-restore /usr/local/bin/oscar-merge-wal-restore

ENV POSTGRES_INITDB_ARGS="--data-checksums --auth-local=scram-sha-256 --auth-host=scram-sha-256 -c max_parallel_workers_per_gather=0 -c max_parallel_workers=0"

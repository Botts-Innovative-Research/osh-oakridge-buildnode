FROM postgis/postgis:16-3.4

COPY init-extensions.sql /docker-entrypoint-initdb.d/init-extensions.sql

ENV POSTGRES_INITDB_ARGS="-c max_parallel_workers_per_gather=0 -c max_parallel_workers=0"
FROM postgis/postgis:16-3.4

#RUN echo "host all all all md5" >> /etc/postgresql/16/main/pg_hba.conf

COPY init-extensions.sql /docker-entrypoint-initdb.d/init-extensions.sql

ENV POSTGRES_INITDB_ARGS="--auth-local=trust --auth-host=scram-sha-256 -c max_parallel_workers_per_gather=0 -c max_parallel_workers=0"
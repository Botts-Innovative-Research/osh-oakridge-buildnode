FROM eclipse-temurin:21.0.10_7-jre-noble@sha256:420374e45e8e9dce3057e768c87a3e8ba58e815049511d8df95ca88a041ec82b

ARG OSCAR_UID=10001
ARG OSCAR_GID=10001

RUN apt-get update \
    && apt-get install --yes --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${OSCAR_GID}" oscar \
    && useradd --uid "${OSCAR_UID}" --gid "${OSCAR_GID}" --home-dir /var/lib/oscar --shell /usr/sbin/nologin oscar

COPY --chown=root:root osh-node-oscar/ /opt/oscar/
COPY --chown=root:root docker/oscar/entrypoint.sh /usr/local/bin/oscar-entrypoint

RUN chmod 0555 /usr/local/bin/oscar-entrypoint \
    && find /opt/oscar -type d -exec chmod 0555 {} \; \
    && find /opt/oscar -type f -exec chmod 0444 {} \; \
    && install --directory --owner=oscar --group=oscar --mode=0700 /var/lib/oscar

USER oscar:oscar
WORKDIR /var/lib/oscar

EXPOSE 8282
ENTRYPOINT ["/usr/local/bin/oscar-entrypoint"]

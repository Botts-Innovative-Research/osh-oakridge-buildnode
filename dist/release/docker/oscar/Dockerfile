FROM eclipse-temurin:21.0.10_7-jre-noble@sha256:420374e45e8e9dce3057e768c87a3e8ba58e815049511d8df95ca88a041ec82b

ARG OSCAR_VERSION=local
ARG OSCAR_UID=10001
ARG OSCAR_GID=10001

LABEL org.opencontainers.image.title="OSCAR" \
      org.opencontainers.image.version="${OSCAR_VERSION}"

COPY --chown=root:root docker/oscar/atomic-publish.c /tmp/oscar-atomic-publish.c

RUN apt-get update \
    && apt-get install --yes --no-install-recommends curl ca-certificates gcc libc6-dev \
    && gcc -O2 -Wall -Wextra -Werror -o /usr/local/bin/oscar-atomic-publish /tmp/oscar-atomic-publish.c \
    && sha256sum /tmp/oscar-atomic-publish.c | awk '{print $1}' > /usr/local/share/oscar-atomic-publish.source.sha256 \
    && chmod 0555 /usr/local/bin/oscar-atomic-publish \
    && chmod 0444 /usr/local/share/oscar-atomic-publish.source.sha256 \
    && rm -f /tmp/oscar-atomic-publish.c \
    && apt-get purge --yes --auto-remove gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${OSCAR_GID}" oscar \
    && useradd --uid "${OSCAR_UID}" --gid "${OSCAR_GID}" --home-dir /var/lib/oscar --shell /usr/sbin/nologin oscar

COPY --chown=root:root osh-node-oscar/ /opt/oscar/
COPY --chown=root:root docker/oscar/entrypoint.sh /usr/local/bin/oscar-entrypoint
COPY --chown=root:root docker/oscar/archive-object-helper.sh /usr/local/bin/oscar-archive-object

RUN chmod 0555 /usr/local/bin/oscar-entrypoint /usr/local/bin/oscar-archive-object \
    && find /opt/oscar -type d -exec chmod 0555 {} \; \
    && find /opt/oscar -type f -exec chmod 0444 {} \; \
    && install --directory --owner=oscar --group=oscar --mode=0700 \
        /var/lib/oscar /run/oscar-native

USER oscar:oscar
WORKDIR /var/lib/oscar

EXPOSE 8282
ENTRYPOINT ["/usr/local/bin/oscar-entrypoint"]

# Образ среды CI: все проверки pipeline выполняются в контейнере этого образа внутри Docker-in-Docker.
# Содержит Python 3.13, make, git, клиент PostgreSQL 17 (pg_dump/pg_restore для проверок резервного
# копирования), docker CLI и плагин compose для контейнерной проверки.
# Версии зафиксированы (не latest); образ кэшируется по хешу этого файла.
FROM docker:27.5.1-cli AS dockercli

FROM python:3.13-slim-trixie
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONUNBUFFERED=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash make git curl openssl ca-certificates gawk findutils coreutils postgresql-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=dockercli /usr/local/libexec/docker/cli-plugins/ /usr/local/libexec/docker/cli-plugins/
WORKDIR /work

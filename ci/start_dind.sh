#!/usr/bin/env bash
# Запускает Docker-in-Docker: отдельный демон Docker в привилегированном контейнере.
# Все дальнейшие docker-команды pipeline (сборка, БД для тестов, контейнерная проверка, сканеры)
# выполняются в этом демоне, а не в демоне самой машины.
# Рабочий каталог пробрасывается в DinD по тому же пути, чтобы работали bind-mount файлы compose.
set -euo pipefail
WS="${GITHUB_WORKSPACE:-$(pwd)}"
DIND_IMAGE="${DIND_IMAGE:-docker:27.5.1-dind}"

mkdir -p "$HOME/.cache/pip"
docker rm -f dind >/dev/null 2>&1 || true
docker run -d --name dind --privileged -e DOCKER_TLS_CERTDIR="" \
  -v "$WS:$WS" -v "$HOME/.cache/pip:$HOME/.cache/pip" \
  -p 127.0.0.1:2375:2375 "$DIND_IMAGE" >/dev/null

export DOCKER_HOST=tcp://127.0.0.1:2375
for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
if ! docker info >/dev/null 2>&1; then
  echo "DinD не запустился" >&2
  DOCKER_HOST= docker logs dind | tail -n 30 >&2
  exit 1
fi
echo "DOCKER_HOST=$DOCKER_HOST" >> "${GITHUB_ENV:-/dev/null}"
echo "DinD готов, версия демона: $(docker version -f '{{.Server.Version}}')"

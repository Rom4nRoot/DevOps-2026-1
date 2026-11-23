#!/usr/bin/env bash
# ci/run.sh КОМАНДА...: выполняет команду в контейнере среды CI внутри DinD.
# Пример: bash ci/run.sh make quality
# Контейнер использует сеть самого DinD (--network host), поэтому порты контейнеров,
# запущенных в DinD (тестовая БД, nginx), доступны по 127.0.0.1.
set -euo pipefail
WS="${GITHUB_WORKSPACE:-$(pwd)}"
: "${DOCKER_HOST:?DinD не запущен: выполните ci/start_dind.sh}"
IMAGE="${CI_IMAGE:-music-store-ci:local}"

exec docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$WS:$WS" -w "$WS" \
  -v "$HOME/.cache/pip:/root/.cache/pip" \
  -e CI=true -e APP_VERSION -e CI_EVENT_FILE -e CI_EVENT_NAME -e CI_BASE_SHA -e GITHUB_REF \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
  "$IMAGE" "$@"

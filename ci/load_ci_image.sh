#!/usr/bin/env bash
# Готовит образ среды CI внутри DinD: из кэша (docker load) или сборкой из ci/Dockerfile.
set -euo pipefail
IMAGE="${CI_IMAGE:-music-store-ci:local}"
TAR=".ci-cache/ci-image.tar"

if [ -f "$TAR" ]; then
  echo "Образ CI из кэша"
  docker load -i "$TAR"
else
  echo "Сборка образа CI"
  docker build -t "$IMAGE" ci/
  mkdir -p .ci-cache
  docker save -o "$TAR" "$IMAGE"
fi

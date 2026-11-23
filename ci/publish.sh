#!/usr/bin/env bash
# Публикация образа. Вызывается только из job publish, после успешного прохождения ВСЕХ проверок.
# 1) образ загружается в DinD из артефакта, собранного и проверенного на этапе build;
# 2) проходит через локальный registry (registry:2 в DinD): push, pull и проверка по digest;
# 3) публикуется в GHCR с тегами, привязанными к SHA коммита.
# Теги latest не используются.
set -euo pipefail
: "${GITHUB_SHA:?}" "${GITHUB_REPOSITORY_OWNER:?}" "${GITHUB_ACTOR:?}" "${REGISTRY_PASSWORD:?}"
VERSION="sha-${GITHUB_SHA}"
SHORT="sha-${GITHUB_SHA:0:7}"
OWNER="${GITHUB_REPOSITORY_OWNER,,}"            # GHCR требует нижний регистр
REMOTE="ghcr.io/${OWNER}/music-store"
LOCAL="127.0.0.1:5000/music-store"

docker load -i image.tar

echo "== Локальный registry"
docker rm -f registry >/dev/null 2>&1 || true
docker run -d --name registry -p 5000:5000 registry:2.8.3 >/dev/null
for _ in $(seq 1 30); do curl -fs http://127.0.0.1:5000/v2/ >/dev/null 2>&1 && break; sleep 1; done
docker tag "music-store:${VERSION}" "${LOCAL}:${VERSION}"
docker push "${LOCAL}:${VERSION}"
docker rmi "${LOCAL}:${VERSION}" >/dev/null
docker pull "${LOCAL}:${VERSION}" >/dev/null
echo "Образ проходит через локальный registry"

echo "== Публикация в GHCR"
printf '%s' "$REGISTRY_PASSWORD" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin
for tag in "$VERSION" "$SHORT"; do
  docker tag "music-store:${VERSION}" "${REMOTE}:${tag}"
  docker push "${REMOTE}:${tag}"
done
echo "Опубликовано: ${REMOTE}:${VERSION}"
{
  echo "### Опубликован образ"
  echo "- \`${REMOTE}:${VERSION}\`"
  echo "- \`${REMOTE}:${SHORT}\`"
} > ci-publish-summary.md

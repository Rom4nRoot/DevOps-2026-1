#!/usr/bin/env bash
# Отдельная тестовая БД для pipeline: свежий PostgreSQL в DinD, база music_store_test.
# Пароль берётся из защищённого секрета CI_TEST_DB_PASSWORD (только латинские буквы и цифры);
# если секрета нет (например, запуск из форка), создаётся случайный.
# Пишет backend/.env.test: именно его читают `make test`, `make migrate-check`, `make backup-check`.
set -euo pipefail
PASS="${CI_TEST_DB_PASSWORD:-}"
[ -n "$PASS" ] || PASS="$(openssl rand -hex 16)"
[[ "$PASS" =~ ^[A-Za-z0-9]+$ ]] || { echo "CI_TEST_DB_PASSWORD: допустимы только латинские буквы и цифры" >&2; exit 1; }
echo "::add-mask::$PASS"

docker rm -f testdb >/dev/null 2>&1 || true
docker run -d --name testdb -e POSTGRES_PASSWORD="$PASS" -e POSTGRES_DB=music_store_test \
  -p 5432:5432 postgres:17-alpine >/dev/null
for _ in $(seq 1 60); do
  docker exec testdb pg_isready -h 127.0.0.1 -U postgres -d music_store_test >/dev/null 2>&1 && break
  sleep 1
done
docker exec testdb pg_isready -h 127.0.0.1 -U postgres -d music_store_test >/dev/null \
  || { docker logs testdb | tail -n 20 >&2; echo "Тестовая БД не запустилась" >&2; exit 1; }

umask 077
printf 'TEST_DATABASE_URL=postgresql+psycopg://postgres:%s@127.0.0.1:5432/music_store_test\n' "$PASS" \
  > backend/.env.test
echo "Тестовая БД готова (music_store_test в DinD)"

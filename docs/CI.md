# Continuous Integration (Лаб. 5)

## Выбор системы: GitHub Actions

| Система | Ресурсы | Вывод |
|---|---|---|
| GitLab CI/CD | сервер GitLab требует около 16 ГБ RAM | не подходит для учебной ВМ |
| Jenkins, TeamCity | отдельный сервер (Java), свои агенты, ручная настройка | возможно, но много обслуживания |
| **GitHub Actions** | серверы предоставляет GitHub, ничего ставить не нужно | **выбран**: репозиторий уже на GitHub, защита веток, CODEOWNERS, секреты, кэш и хранилище артефактов встроены |

## Схема pipeline

Файл `.github/workflows/ci.yml`. Запускается при `push` в любую ветку, при создании и обновлении Pull Request в `main`
и при изменении `main`.

```
 guard ─┐
 style ─┤
 policy ┤
 test ──┼─► build ─► publish (только push в main)
 migrations ┤
 backup ┤
 security ┤
 container ┘
```

| Job | Команда (та же, что локально) | Что ловит | Отчёты |
|---|---|---|---|
| `guard` | `scripts/ci_guard.py` | изменение критических файлов, удаление тестов, снижение порогов, обходы проверок | сводка в интерфейсе |
| `style` | `make quality` | стиль, ошибки, форматирование (ruff) | |
| `policy` | `make policy` | запреты проекта, секреты, версии, защита pipeline | |
| `test` | `make test` | unit- и интеграционные тесты, покрытие | `junit.xml`, `coverage.xml`, `htmlcov/` |
| `migrations` | `make migrate-check` | миграции на чистой и заполненной БД | |
| `backup` | `make backup-check` | резервная копия, порча данных, восстановление | |
| `security` | `make sast`, `make audit`, `make secrets` | bandit, pip-audit, gitleaks | `bandit.json`, `pip-audit.txt`, `gitleaks.json` |
| `container` | `make container-check` | вся контейнерная проверка из лаб. 4 | |
| `build` | `make image`, `make image-scan` | образ с тегом `sha-<коммит>`, анализ trivy | `trivy.json`, артефакт `image.tar` |
| `publish` | `ci/publish.sh` | публикация через локальный registry в GHCR | |

## Docker-in-Docker

Все проверки выполняются в DinD (`ci/start_dind.sh`): на машине запускается привилегированный контейнер `docker:dind`
со своим демоном Docker. Дальше все `docker`-команды pipeline идут в этот демон, а не в демон самой машины.

- Сами команды (`make ...`) выполняются в контейнере среды CI (`ci/Dockerfile`: Python 3.13, make, git, клиент PostgreSQL 17,
  docker CLI) внутри DinD через `ci/run.sh`. Контейнер использует сеть DinD (`--network host`), поэтому порты контейнеров,
  запущенных в DinD (тестовая БД, nginx), доступны по `127.0.0.1`.
- Тестовая БД (`ci/prepare_test_db.sh`): свежий PostgreSQL 17 в DinD, база `music_store_test`, отдельная для каждого job.
- Рабочий каталог пробрасывается в DinD по тому же пути, чтобы работали файлы, подключаемые в `compose.yaml`.
- Образ `registry:2` в DinD служит локальным registry: образ проходит через него перед публикацией (`ci/publish.sh`).

## Кэширование

- зависимости Python: `actions/cache` для `~/.cache/pip`, ключ из хеша `backend/requirements-dev.txt`;
- образ среды CI: `.ci-cache/ci-image.tar`, ключ из хеша `ci/Dockerfile` (`docker load` вместо сборки).

## Секреты и права

| Что | Где хранится |
|---|---|
| пароль тестовой БД | секрет репозитория `CI_TEST_DB_PASSWORD` (без него создаётся случайный) |
| вход в GHCR | автоматический `GITHUB_TOKEN`, права `packages: write` только у job `publish` |

Секреты не попадают в репозиторий и в образ, в журналах маскируются (`::add-mask::`).
Остальные job работают с правами `contents: read`.

## Защита критических файлов

Критические файлы перечислены в `ci/critical-files.txt` и `.github/CODEOWNERS`: pipeline, `Makefile`, `quality-baseline.txt`,
`pyproject.toml`, тесты, миграции, `Dockerfile`, `compose.yaml`, настройки анализаторов.

| Механизм | Что гарантирует |
|---|---|
| CODEOWNERS и правило «Require review from Code Owners» | изменение критического файла не сольётся без отзыва владельца |
| обязательные проверки (`scripts/ci_protect_branch.sh`) | без зелёных job слияние невозможно; если удалить job из workflow, проверка не будет выполнена, и слияние останется заблокированным |
| `guard` | видно и блокируется ослабление: меньше тестов, ниже пороги, `continue-on-error`, `|| true`, `if: false`, `exit 0` |
| `make policy` | не даёт убрать обязательные job и зависимости публикации, пропускать и удалять тесты, держать секреты в git |
| метка `quality-waiver` | единственный способ пропустить `guard`; ставит владелец, нарушения остаются в сводке |

## Демонстрации для защиты

Каждая выполняется на отдельной ветке с Pull Request.

1. **Сломанный тест.** В `backend/app/routes/sales.py` замените `<` на `<=` в проверке остатка. Job `test` красный, `build` и `publish` пропущены.
2. **Сломанная миграция.** В `backend/ale/versions/9e8f7a6b5c4d_restrict_user_roles.py` измените имя таблицы `users` на `user`. Красные `migrations` и `test`.
3. **Секрет.** Добавьте файл `backend/demo.txt` со строкой `AWS_ACCESS_KEY_ID=AKIAQ3EGRJ4ZT7WNB2XD`. Красный `security`, отчёт `gitleaks.json` в артефактах.
4. **Образ не публикуется после ошибки.** При любой из ошибок выше `publish` не запускается. После слияния корректного изменения в `main` в разделе Packages появляется образ `sha-<коммит>`.
5. **Защита файлов.** Удалите тест или снизьте `fail_under` в `backend/pyproject.toml`: красные `guard` и `policy`, а в Pull Request запрошен отзыв владельца.

## Почему локальные и серверные проверки должны совпадать

- Если CI проверяет не то же, что разработчик, зелёный локальный `make verify` ничего не гарантирует, а красный CI невозможно воспроизвести.
- Поэтому pipeline вызывает те же цели `make` и использует те же файлы версий (`requirements-dev.txt`, теги образов).
- Локальная проверка быстрая и даёт обратную связь до коммита, серверная независимая: её нельзя обойти (`--no-verify`, чужая машина с другими версиями) и она обязательна для слияния.

## Ограничения

- Теги действий (`actions/checkout@v4` и др.) и образов (`docker:27.5.1-dind`, `zricethezav/gitleaks:v8.21.2`, `aquasec/trivy:0.58.1`, `registry:2.8.3`) нужно периодически обновлять; если тег исчез, замените его на существующий. Надёжнее закрепить действия по SHA.
- Анонимные скачивания образов с Docker Hub ограничены по числу: при ошибке `toomanyrequests` добавьте вход в Docker Hub с секретами.
- Защита веток для приватных репозиториев требует платного тарифа GitHub.

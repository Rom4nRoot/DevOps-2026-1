# Единый командный интерфейс проекта. Все команды запускаются из корня репозитория.
# Критический файл приёмки: ослаблять проверки нельзя (CONTRIBUTING.md, раздел 2).

SHELL := /bin/bash
PYTHON ?= python3
BACKEND := backend
VBIN := $(BACKEND)/venv/bin
# Подключает настройки тестовой БД (backend/.env.test) к одной команде
WITH_TEST_ENV = set -a; . ./$(BACKEND)/.env.test; set +a;

.DEFAULT_GOAL := help
.PHONY: help setup lock run test test-unit migrate-check quality format sast policy \
	    migrate backup restore mutate verify clean

help: ## Список команд
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

setup: ## Первоначальная настройка: окружение, зависимости, базы, миграции
	PYTHON=$(PYTHON) scripts/bootstrap.sh

lock: ## Зафиксировать точные версии зависимостей (requirements*.txt)
	PYTHON=$(PYTHON) scripts/lock.sh

run: ## Запустить приложение для разработки (http://localhost:8000)
	cd $(BACKEND) && venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload

test: ## Все тесты + покрытие + отчёты (backend/reports/)
	$(WITH_TEST_ENV) cd $(BACKEND) && venv/bin/pytest

test-unit: ## Только быстрые unit-тесты (без базы данных)
	cd $(BACKEND) && venv/bin/pytest -m unit --no-cov

migrate-check: ## Проверка миграций на чистой и заполненной БД
	$(WITH_TEST_ENV) cd $(BACKEND) && venv/bin/pytest -m migrations --no-cov

quality: ## Линтер и проверка форматирования (ruff)
	cd $(BACKEND) && venv/bin/ruff check . && venv/bin/ruff format --check .

format: ## Автоматически исправить форматирование и импорты
	cd $(BACKEND) && venv/bin/ruff check --fix . && venv/bin/ruff format .

sast: ## Статический анализ безопасности (bandit), отчёт backend/reports/bandit.json
	mkdir -p $(BACKEND)/reports
	-cd $(BACKEND) && venv/bin/bandit -q -c pyproject.toml -r app ale -f json -o reports/bandit.json
	cd $(BACKEND) && venv/bin/bandit -q -c pyproject.toml -r app ale

policy: ## Запреты: пропуск тестов, снижение порогов, исключения, секреты, версии
	$(VBIN)/python scripts/check_policy.py

migrate: ## Применить миграции к рабочей БД (backend/.env)
	cd $(BACKEND) && venv/bin/alembic upgrade head

backup: ## Резервная копия рабочей БД в каталог backups/
	bash scripts/backup.sh

restore: ## Восстановление: make restore FILE=backups/<файл>.dump
	@test -n "$(FILE)" || { echo "Укажите файл: make restore FILE=backups/<файл>.dump"; exit 2; }
	bash scripts/restore.sh "$(FILE)"

mutate: ## Мутационная проверка: тесты должны замечать изменение условий
	$(WITH_TEST_ENV) $(VBIN)/python scripts/mutation_check.py

verify: policy quality sast test ## Полный набор обязательных проверок

clean: ## Удалить отчёты и кэши
	rm -rf $(BACKEND)/reports $(BACKEND)/.pytest_cache $(BACKEND)/.ruff_cache $(BACKEND)/.coverage

# ---------- Лаб. 4: контейнерное окружение (запускать на Linux-машине с Docker) ----------
COMPOSE := docker compose --env-file .env.docker

container-env: ## Создать .env.docker со случайными паролями (в git не попадает)
	bash scripts/container_env.sh

build: ## Собрать образ приложения
	@bash scripts/container_env.sh >/dev/null
	$(COMPOSE) build

up: ## Собрать и запустить окружение: nginx, 2 экземпляра приложения, БД
	bash scripts/container_up.sh

down: ## Остановить окружение (данные в volume сохраняются)
	$(COMPOSE) down

ps: ## Состояние контейнеров
	$(COMPOSE) ps

logs: ## Журналы контейнеров (Ctrl+C для выхода)
	$(COMPOSE) logs -f --tail 50

container-check: ## Автоматическая проверка контейнерного окружения
	bash scripts/container_check.sh

container-backup: ## Резервная копия БД из контейнера в backups/
	bash scripts/container_backup.sh

container-restore: ## Восстановить БД в текущем окружении: make container-restore FILE=backups/x.dump
	@test -n "$(FILE)" || { echo "Укажите файл: make container-restore FILE=backups/<файл>.dump"; exit 2; }
	bash scripts/container_restore.sh "$(FILE)"

container-restore-new: ## Восстановить БД в НОВЫЙ volume: make container-restore-new FILE=backups/x.dump
	@test -n "$(FILE)" || { echo "Укажите файл: make container-restore-new FILE=backups/<файл>.dump"; exit 2; }
	bash scripts/container_restore.sh --new-volume "$(FILE)"

# ---------- Лаб. 5: команды, которые выполняет CI (те же, что и локально) ----------
GIT_SHA ?= $(shell git rev-parse HEAD 2>/dev/null)
REPO_URL ?= https://github.com/Skilzarik/DevOps-2026-1
APP_VERSION ?= dev
GITLEAKS_IMAGE ?= zricethezav/gitleaks:v8.21.2
TRIVY_IMAGE ?= aquasec/trivy:0.58.1

deps: ## Создать backend/venv и поставить зависимости (без настройки БД)
	[ -x $(VBIN)/python ] || $(PYTHON) -m venv $(BACKEND)/venv
	$(VBIN)/pip install -q -r $(BACKEND)/requirements-dev.txt

backup-check: ## Резервная копия, повреждение данных и восстановление (на тестовой БД)
	$(WITH_TEST_ENV) cd $(BACKEND) && venv/bin/pytest tests/test_backup_restore.py --no-cov

audit: ## Проверка зависимостей на известные уязвимости (pip-audit)
	mkdir -p $(BACKEND)/reports
	set -o pipefail; cd $(BACKEND) && venv/bin/pip-audit -r requirements.txt --no-deps --disable-pip --progress-spinner off 2>&1 | tee reports/pip-audit.txt

secrets: ## Поиск секретов в файлах проекта (gitleaks в Docker)
	mkdir -p $(BACKEND)/reports
	docker run --rm -v "$(CURDIR):/repo" -w /repo $(GITLEAKS_IMAGE) detect --source /repo --no-git --redact -v --config /repo/.gitleaks.toml --report-format json --report-path /repo/backend/reports/gitleaks.json

image: ## Собрать образ приложения с тегом APP_VERSION (в CI: sha-<commit>)
	docker build -t music-store:$(APP_VERSION) --label org.opencontainers.image.revision=$(GIT_SHA) --label org.opencontainers.image.source=$(REPO_URL) .

image-scan: ## Анализ образа на уязвимости HIGH/CRITICAL (trivy)
	mkdir -p $(BACKEND)/reports
	test -f image.tar || docker save music-store:$(APP_VERSION) -o image.tar
	docker run --rm -v "$(CURDIR):/work" -w /work $(TRIVY_IMAGE) image --input /work/image.tar --cache-dir /work/.trivycache --severity HIGH,CRITICAL --ignore-unfixed --format json --output /work/backend/reports/trivy.json
	docker run --rm -v "$(CURDIR):/work" -w /work $(TRIVY_IMAGE) image --input /work/image.tar --cache-dir /work/.trivycache --skip-db-update --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1

ci-guard: ## Защита критических файлов: сравнение с origin/main (как в CI)
	python3 scripts/ci_guard.py

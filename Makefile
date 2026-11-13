# bi-ml-models — разработка и тестирование моделей прогнозирования.
#
# Числа считаются только скриптами; ноутбуки — учебные и не заменяют прогон.
# Данные: ClickHouse read-only (CLICKHOUSE_URL из ~/.config/rosstat/env или env).
# Запись: ml_runs/ml_predictions (паспорт) и ingest-контур для live-прогноза.

SHELL := /bin/bash
PYTHON ?= 3.12
UV ?= uv
RUN := $(UV) run --python $(PYTHON)
RUN_TEST := $(UV) run --python $(PYTHON) --extra test
ARGS ?=

BUILD_DIR := build

# MLflow: по умолчанию — staging-туннель (канонические run'ы).
# Локальный dev-сервер: make mlflow-up и MLFLOW_TRACKING_URI=http://127.0.0.1:$(MLFLOW_PORT).
MLFLOW_VERSION      ?= 3.17.1
MLFLOW_HOME         ?= $(BUILD_DIR)/mlflow
MLFLOW_PORT         ?= 5000
MLFLOW_TRACKING_URI ?= http://127.0.0.1:15001
MLFLOW_TRACKING_URI_EXPLICIT := $(if $(filter environment command line,$(origin MLFLOW_TRACKING_URI)),1,)
MLFLOW_LOCAL_URI    := http://127.0.0.1:$(MLFLOW_PORT)
MLFLOW_DB           := $(abspath $(MLFLOW_HOME)/mlflow.db)
MLFLOW_ARTIFACTS    := $(abspath $(MLFLOW_HOME)/artifacts)
MLFLOW_PID          := $(MLFLOW_HOME)/mlflow.pid
MLFLOW_LOG          := $(MLFLOW_HOME)/mlflow.log

MLFLOW ?= 1
MLFLOW_PKG    := $(if $(filter 1,$(MLFLOW)),--with "mlflow==$(MLFLOW_VERSION)",)
MLFLOW_ENV    := $(if $(filter 1,$(MLFLOW)),MLFLOW_TRACKING_URI=$(MLFLOW_TRACKING_URI),MLFLOW_TRACKING_URI=)
MLFLOW_HTTP_ENV := MLFLOW_HTTP_REQUEST_TIMEOUT=10 MLFLOW_HTTP_REQUEST_MAX_RETRIES=2
MLFLOW_PREFLIGHT := $(if $(filter 1,$(MLFLOW)),python3 tools/mlflow_preflight.py --uri $(MLFLOW_TRACKING_URI),true)

CB_COMP_SHADOW_UV = uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3
CB_COMP_REVIEW_DIR := build/cb-comp-per-code-review

.PHONY: all test test-bi-ml test-tools test-models notebooks-check compile \
        mlflow-up mlflow-down mlflow-status mlflow-tunnel mlflow-preflight \
        mlflow-export mlflow-backfill ml-gate ml-live-check

all: test

# Полный офлайн-набор: без ClickHouse и сети.
test: test-bi-ml test-tools test-models

test-bi-ml:
	$(RUN_TEST) python3 -m unittest discover -t . -s bi_ml -p '*_test.py'

test-tools:
	$(RUN_TEST) python3 -m unittest discover -t . -s tools -p '*_test.py'

test-models:
	$(RUN_TEST) python3 -m unittest discover -t . -s models -p '*_test.py'

compile:
	$(RUN) python3 -m compileall -q bi_ml tools models

notebooks-check:
	$(RUN) --extra notebooks bash -c 'mkdir -p build/notebooks && for nb in notebooks/*.ipynb; do \
		echo "== $$nb"; jupyter nbconvert --to notebook --execute --output-dir build/notebooks "$$nb" || exit 1; done'

# SSH-туннель к staging MLflow (127.0.0.1:5000 хоста -> локальный 15001).
mlflow-tunnel:
	ssh -N -L 15001:127.0.0.1:5000 palmshell

mlflow-up:
	@if curl -sf -m 2 http://127.0.0.1:$(MLFLOW_PORT)/health >/dev/null 2>&1; then \
		echo "MLflow уже отвечает на порту $(MLFLOW_PORT)"; \
	else \
		if [ -f "$(MLFLOW_PID)" ]; then \
			pid=$$(cat "$(MLFLOW_PID)"); \
			if kill -0 $$pid 2>/dev/null && ps -p $$pid -o command= | grep -q mlflow; then \
				echo "MLflow уже запускается/запущен (PID $$pid), второй сервер не поднимается"; \
				exit 0; \
			fi; \
			if kill -0 $$pid 2>/dev/null; then \
				echo "PID-файл $(MLFLOW_PID) устарел: PID $$pid принадлежит не MLflow — файл удалён, процесс не тронут"; \
			else \
				echo "PID-файл $(MLFLOW_PID) устарел: процесс $$pid не запущен — файл удалён"; \
			fi; \
			rm -f "$(MLFLOW_PID)"; \
		fi; \
		mkdir -p "$(MLFLOW_HOME)" "$(MLFLOW_ARTIFACTS)"; \
		echo "прогрев uv-окружения mlflow==$(MLFLOW_VERSION) (первый запуск скачивает пакет)..."; \
		uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 python -c "pass" || exit 1; \
		nohup uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 mlflow server \
			--host 127.0.0.1 --port $(MLFLOW_PORT) --workers 1 \
			--backend-store-uri "sqlite:///$(MLFLOW_DB)" \
			--artifacts-destination "$(MLFLOW_ARTIFACTS)" --serve-artifacts >"$(MLFLOW_LOG)" 2>&1 & \
		echo $$! > "$(MLFLOW_PID)"; \
		for i in $$(seq 1 60); do kill -0 $$(cat "$(MLFLOW_PID)") 2>/dev/null || break; curl -sf -m 1 http://127.0.0.1:$(MLFLOW_PORT)/health >/dev/null 2>&1 && break; sleep 1; done; \
		if kill -0 $$(cat "$(MLFLOW_PID)") 2>/dev/null && curl -sf -m 2 http://127.0.0.1:$(MLFLOW_PORT)/health >/dev/null 2>&1; then \
			echo "MLflow запущен на порту $(MLFLOW_PORT), PID $$(cat "$(MLFLOW_PID)"), лог $(MLFLOW_LOG)"; \
		else \
			pid=$$(cat "$(MLFLOW_PID)"); \
			kill $$pid 2>/dev/null || true; \
			for i in $$(seq 1 10); do kill -0 $$pid 2>/dev/null || break; sleep 1; done; \
			kill -9 $$pid 2>/dev/null || true; \
			rm -f "$(MLFLOW_PID)"; \
			echo "MLflow не поднялся, хвост $(MLFLOW_LOG):"; tail -30 "$(MLFLOW_LOG)"; exit 1; \
		fi; \
	fi

# Останавливает сервер и ждёт завершения до 60 с. PID-файл удаляется только после
# фактического завершения; БД и артефакты не трогаются. Процесс из PID-файла
# проверяется по идентичности: чужой/устаревший PID не убивается, файл удаляется.
mlflow-down:
	@if [ -f "$(MLFLOW_PID)" ]; then \
		pid=$$(cat "$(MLFLOW_PID)"); \
		if ! kill -0 $$pid 2>/dev/null; then \
			echo "PID-файл $(MLFLOW_PID) устарел: процесс $$pid не запущен — файл удалён"; \
			rm -f "$(MLFLOW_PID)"; \
		elif ! ps -p $$pid -o command= | grep -q mlflow; then \
			echo "PID $$pid из $(MLFLOW_PID) принадлежит не MLflow — файл удалён, процесс не тронут"; \
			rm -f "$(MLFLOW_PID)"; \
		else \
			kill $$pid; \
			for i in $$(seq 1 60); do kill -0 $$pid 2>/dev/null || break; sleep 1; done; \
			if kill -0 $$pid 2>/dev/null; then \
				echo "MLflow не завершился за 60 с, PID-файл $(MLFLOW_PID) сохранён: повторите make mlflow-down"; \
			else \
				rm -f "$(MLFLOW_PID)"; echo "MLflow остановлен"; \
			fi; \
		fi; \
	else \
		echo "PID-файл $(MLFLOW_PID) не найден или процесс не запущен (сервер, поднятый вне make, не останавливается)"; \
	fi

mlflow-status:
	@curl -sf -m 2 http://127.0.0.1:$(MLFLOW_PORT)/health >/dev/null 2>&1 && echo "MLflow отвечает на порту $(MLFLOW_PORT)" || echo "MLflow не отвечает на порту $(MLFLOW_PORT)"

# Preflight MLflow API: ML-цели вызывают его до старта прогона. Если API не
# отвечает, скрипт явно спрашивает, запускать ли без лога; в неинтерактивном
# режиме — запрещает, пока не выставлен MLFLOW_ALLOW_NO_LOG=1.
mlflow-preflight:
	$(RUN) python3 tools/mlflow_preflight.py --uri $(MLFLOW_TRACKING_URI)

# Backfill существующих прогонов ClickHouse ml_runs в MLflow по run_id:
# make mlflow-backfill ARGS="--run-id <uuid> [--run-id <uuid>] [--force]"
mlflow-backfill:
	MLFLOW_TRACKING_URI=$(MLFLOW_TRACKING_URI) $(MLFLOW_HTTP_ENV) uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 \
		python3 tools/mlflow_backfill.py --tracking-uri $(MLFLOW_TRACKING_URI) $(ARGS)

mlflow-backfill-test:
	$(RUN) python3 tools/mlflow_backfill_test.py -v

# Экспорт прогонов MLflow в ClickHouse (ml_runs/ml_predictions): make mlflow-export
# [ARGS="--since 2026-10-01 --limit 20 --dry-run"]. mlflow ставится через uv --with,
# в зависимости репозитория не попадает.
mlflow-export:
	MLFLOW_TRACKING_URI=$(MLFLOW_TRACKING_URI) $(MLFLOW_HTTP_ENV) uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 \
		python3 tools/mlflow_export.py --tracking-uri $(MLFLOW_TRACKING_URI) $(ARGS)

# Реестр моделей MLflow: register/promote/list. Аргументы подкоманды передаются через ARGS:
# make mlflow-register ARGS="--run-id <id> --name cpi_nowcast_catboost_direct"
# make mlflow-promote ARGS="--name cpi_nowcast_catboost_direct --version 1 [--alias challenger]"
# make mlflow-models [ARGS="--name cpi_nowcast_catboost_direct"]
mlflow-register:
	$(MLFLOW_HTTP_ENV) uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 \
		python3 tools/mlflow_registry.py --tracking-uri $(MLFLOW_TRACKING_URI) register $(ARGS)

mlflow-promote:
	$(MLFLOW_HTTP_ENV) uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 \
		python3 tools/mlflow_registry.py --tracking-uri $(MLFLOW_TRACKING_URI) promote $(ARGS)

mlflow-models:
	$(MLFLOW_HTTP_ENV) uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 \
		python3 tools/mlflow_registry.py --tracking-uri $(MLFLOW_TRACKING_URI) list $(ARGS)

# Gate промоушена (infra/4.3): champion vs challenger на общих фолдах —
# RMSE, DM-HLN, 95% блочный бутстрап, robustness-окна и 90% MCS (>2 кандидатов).
# make ml-gate ARGS="--challenger-run <uuid> --champion-run <uuid> --model ordered_logit"
# Live-оценка shadow/canary: make ml-gate ARGS="--live --live-track cbr_rate:ordered_logit"
# Артефакт — build/ml-gate/<run>.json; при MLFLOW=1 ставятся теги решения.
ml-gate:
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) \
		--with "statsmodels>=0.15" --with scipy --with arch --python 3.12 \
		python3 tools/gate.py $(ARGS)

ml-gate-test:
	uv run --with "statsmodels>=0.15" --with scipy --python 3.12 \
		python3 tools/gate_test.py -v

# Проверка live-прогноза до публикации (infra/4.3): production-строки
# cbr_rate:taylor/ordered_logit на ближайшее заседание, записанные до target_date.
# make ml-live-check [ARGS="--require-llm --warn-only"]
ml-live-check:
	uv run --python 3.12 python3 tools/live_check.py $(ARGS)

ml-live-check-test:
	uv run --python 3.12 python3 tools/live_check_test.py -v

dcf-aisc:
	$(RUN) python3 models/polyus/aisc.py

# ОПР-выпуск Сухого Лога 2025-2027: руда перерабатывается на Вернинской ЗИФ, и Полюс
# показывает результат в производственных результатах Вернинского (сноска 13 пресс-релиза 1П2026),
# но в модели эти годы не входили в NAV ни одного актива. Пишет sql/polyus_output_seed.sql и
# polyus_output_attribution_long.csv, в ClickHouse НЕ пишет — вставка отдельно:
# make ch-sql FILE=sql/polyus_output_seed.sql
polyus-output:
	$(RUN) python3 models/polyus/polyus_output_model.py

# Дополнительные аргументы цели key-rate-model (например, экспорт фикстур тестов).
ARGS ?=

# Первый срез модели ключевой ставки (фундаментальный контур v0): выборка решений,
# бенчмарки, методы №2–3, walk-forward-бэктест. Читает ClickHouse, пишет локальные
# артефакты; в ClickHouse по умолчанию не пишет; с ML_LOG=1 пишет паспорт
# и fold-предсказания. Фикстуры офлайн-тестов: make key-rate-model ARGS="--export-fixtures testdata/key_rate"
# --python 3.12 — не украшение: statsmodels>=0.15 требует Python>=3.10, а `python3` из
# PATH не везде 3.10+ (на машине разработки системный /usr/bin/python3 — 3.9.6, и
# без пина резолвер uv падает). Пин делает цель независимой от порядка PATH и
# повторяет конвенцию репозитория для uv-прогонов (README/ARCHITECTURE: --python 3.12).
key-rate-model:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_model.py $(ARGS)

# cbr_rule — калиброванное правило ДДКП ЦБ как отдельный экспериментальный трек
# (issue #268, спека docs/specs/2026-10-20-cbr-rule-design.md).
# Читает ClickHouse, пишет ЛОКАЛЬНЫЕ артефакты (report/predictions/diagnostics/
# forecast) и НЕ пишет в forecast_log; ML_LOG=1 — паспорт и fold-предсказания
# через ml_experiment. ARGS: --as-of YYYY-MM-DD, --out-dir DIR, --rolling.
key-rate-cbr-rule:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_cbr_rule.py $(ARGS)

# Офлайн-тесты cbr_rule: без ClickHouse и сети.
key-rate-cbr-rule-test:
	uv run --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_cbr_rule_test.py -v

# Сценарный веер ставки с shock-aware слоем (issue #272, Task 1;
# спека docs/specs/2026-10-20-cbr-scenario-fan-design.md).
# Читает ClickHouse, пишет ЛОКАЛЬНЫЕ артефакты (report/predictions/diagnostics/
# forecast) и НЕ пишет в forecast_log; ML_LOG=1 — паспорт и fold-предсказания.
# ARGS: --as-of YYYY-MM-DD, --out-dir DIR, --rolling.
key-rate-scenario-fan:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_scenario_fan.py $(ARGS)

# Офлайн-тесты веера: без ClickHouse и сети.
key-rate-scenario-fan-test:
	uv run --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_scenario_fan_test.py -v

# Веер v2: ядро ordered logit/ML + модель дисперсии (issue #286, Task 3;
# спека docs/specs/2026-10-20-cbr-scenario-fan-v2-design.md).
# Читает ClickHouse, пишет ЛОКАЛЬНЫЕ артефакты и НЕ пишет в forecast_log;
# ML_LOG=1 — паспорт и fold-предсказания через ml_experiment.
key-rate-scenario-fan-v2:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_scenario_fan_v2.py $(ARGS)

# Офлайн-тесты веера v2: без ClickHouse и сети.
key-rate-scenario-fan-v2-test:
	uv run --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_scenario_fan_v2_test.py -v

# Веер v3: channel-complete ядро ElasticNetCV + volatility-дисперсия
# (issue #289, Task 4; спека docs/specs/2026-10-20-cbr-scenario-fan-v3-design.md).
# Читает ClickHouse, пишет ЛОКАЛЬНЫЕ артефакты и НЕ пишет в forecast_log;
# ML_LOG=1 — паспорт и fold-предсказания через ml_experiment.
key-rate-scenario-fan-v3:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_scenario_fan_v3.py $(ARGS)

# Офлайн-тесты веера v3: без ClickHouse и сети.
key-rate-scenario-fan-v3-test:
	uv run --with "statsmodels>=0.15" --with pandas --with scikit-learn --with scipy --python 3.12 python3 models/key_rate/key_rate_scenario_fan_v3_test.py -v

# CPI v3 h1/h3/h6 как model-based прокси ожидаемой инфляции
# (issue #296, Task 4.1; спека docs/specs/2026-10-20-cpi-v3-expectations-design.md).
# Читает ClickHouse, пишет ЛОКАЛЬНЫЕ артефакты в build/; в forecast_log не пишет.
key-rate-cpi-v3-experiment:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/key_rate/key_rate_cpi_v3_experiment.py $(ARGS)

# Live-диагностика CPI h1/h3/h6 для заседания: make cpi-live3-horizons ARGS="--as-of 2026-10-23 --meeting 2026-10-23".
cpi-live3-horizons:
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_live3_horizons.py $(ARGS)

# Офлайн-тесты CPI h1/h3/h6 и эксперимента: без ClickHouse и сети.
cpi-live3-horizons-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_live3_horizons_test.py -v

key-rate-cpi-v3-experiment-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/key_rate/key_rate_cpi_v3_experiment_test.py -v

# Классификатор шоков ключевой ставки (спека 2026-10-19, §8): панель заседаний,
# as-of каналы, причинные веса (Махаланобис + Ledoit–Wolf) и описательный
# логистический классификатор явных шоков. Читает ClickHouse, пишет ЛОКАЛЬНЫЕ
# артефакты в каталог прогона (по умолчанию текущий): shock_classifier_report.md,
# shock_classifier_weights.csv, shock_classifier_forecast.json. В ClickHouse
# напрямую не пишет; ML_LOG=1 (или ARGS="--log") — паспорт, метрики и
# предсказания через ml_experiment (ml_runs/ml_predictions).
# ARGS="--features core|all --min-train N --out-dir DIR"; фикстуры:
# make shock-classifier ARGS="--export-fixtures testdata/shock_classifier"
shock-classifier:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/key_rate/shock_classifier.py $(ARGS)

# Офлайн-тесты классификатора шоков: без ClickHouse и сети.
shock-classifier-test:
	uv run --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/key_rate/shock_classifier_test.py -v

# Запись текущего прогноза ставки в forecast_log через ingest (POST /v1/key_rate_forecast).
# Читает локальные артефакты key_rate_model_forecast.json (и, при наличии,
# key_rate_llm_forecast.json), в ClickHouse напрямую не пишет. Нужны INGEST_URL и
# INGEST_TOKEN из $(ROSSTAT_ENV); ingest-сервис — make run-ingest.
# Отладка: make key-rate-forecast-log ARGS="--dry-run"
key-rate-forecast-log:
	uv run --python 3.12 python3 tools/forecast_log.py $(ARGS)

# Экспериментальный LLM-трек контура ставки (issue #189): as-of снимок витрин,
# промпт v1, три OpenAI-совместимых повтора, медиана и разброс, артефакты
# key_rate_llm_forecast.json / key_rate_llm_forecast_report.md (gitignored).
# Зависимостей вне stdlib нет; нужны ClickHouse env и LLM_BASE_URL/LLM_API_KEY/
# LLM_MODEL (последние — только в ~/.config/rosstat/env). В ClickHouse скрипт
# НЕ пишет; ARGS="--log" готовит payload для ingest #127 и печатает его.
key-rate-llm-forecast:
	uv run --python 3.12 python3 models/key_rate/key_rate_llm_forecast.py $(ARGS)
# ML-трек контура ставки: nowcast месячного ИПЦ до публикации Росстата (CatBoost + бенчмарки).
# Читает ClickHouse, пишет локальные артефакты; в ClickHouse по умолчанию не пишет;
# с ML_LOG=1 пишет паспорт и fold-предсказания.
# Фикстуры: make cpi-nowcast ARGS="--export-fixtures testdata/cpi_nowcast"
cpi-nowcast:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_nowcast.py $(ARGS)

# ML-трек v2: месячный nowcast ИПЦ с мониторингом предприятий ЦБ (с МП vs без МП).
# Читает ClickHouse, пишет локальные артефакты; по умолчанию в ClickHouse НЕ пишет;
# с ML_LOG=1 пишет паспорт и fold-предсказания в ml_runs/ml_predictions.
# Фикстуры: make cpi-monthly ARGS="--export-fixtures testdata/cpi_monthly"
cpi-monthly:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly.py $(ARGS)

# Stage 1 #76: публичные недельные признаки в месячном nowcast ИПЦ.
cpi-monthly-v3:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly_v3.py $(ARGS)

cpi-monthly-v3-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly_v3_test.py -v

# Task 4 #237: v3 на публичных данных — industry MP из v_cbr_survey (#239),
# h1/h2/h3/h6, direct/bottom-up, B1–B3, DM/CI/MDE; в ClickHouse не пишет.
cpi-monthly-v3-public:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly_v3_public.py $(ARGS)

cpi-monthly-v3-public-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly_v3_public_test.py -v

# Live-адаптация production-пайплайна CB_COMP (схема авторов): официальные
# 4 компонента + недельные товары + МП + FAO/USD/ставка → 3 компонентных
# CatBoost → агрегат, ошибки, дашборд, ЖКУ, экспертные корректировки, Россия.
# Читает ClickHouse и архив; в БД не пишет.
cb-comp-live:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_live_pipeline.py $(ARGS)

# Офлайн-тесты live-пайплайна: без ClickHouse и архива.
cb-comp-live-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_live_pipeline_test.py -v

# Сравнение live 3-компонентной модели, per-sheet и CB_COMP на общем таргете
# TARGET_FULL (54 normal-месяца, origin M−(h−1)). Читает ClickHouse и архив.
cb-comp-live-compare:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_live_compare.py $(ARGS)

# Stage 2 #235: отраслевые МП-признаки (16 листов mp_survey_data.xlsx) в
# компонентном nowcast ИПЦ. Читает ClickHouse и публичный xlsx; в БД не пишет.
cpi-monthly-industry:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly_industry.py $(ARGS)

cpi-monthly-industry-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_monthly_industry_test.py -v

# Task 1 #234: аудит публичной панели ИПЦ. Читает ClickHouse и публичные xlsx,
# в БД не пишет; JSON — docs/research/2026-10-19-cpi-public-data-audit.json.
cpi-public-audit:
	uv run --with openpyxl --python 3.12 python3 models/cpi/cpi_public_panel_audit.py $(ARGS)

cpi-public-audit-test:
	uv run --with openpyxl --python 3.12 python3 models/cpi/cpi_public_panel_audit_test.py -v

# #348: недельный прокси базовой инфляции — 4-нед. средняя, календарная
# регрессия, STL(52) и Gate 0 X-13. Читает ClickHouse, в БД не пишет;
# JSON — docs/research/2026-10-22-weekly-core-proxy.json.
weekly-core-proxy:
	uv run --with "statsmodels>=0.15" --with numpy --with scipy --with "holidays>=0.60" --python 3.12 python3 models/cpi/weekly_core_proxy.py $(ARGS)

weekly-core-proxy-test:
	uv run --with "statsmodels>=0.15" --with numpy --with scipy --with "holidays>=0.60" --python 3.12 python3 models/cpi/weekly_core_proxy_test.py -v

# #396 Task 1: аудит недельного агрегата ИПЦ 2009+ (признаки wkagg_* — Task 2).
# Читает ClickHouse; в БД не пишет.
cpi-weekly-aggregate:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_weekly_aggregate.py $(ARGS)

cpi-weekly-aggregate-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_weekly_aggregate_test.py -v

# #396 Task 4: каркас лидерборда CPI v4 и регрессионный гейт v2/v3 на S_W22.
# Читает ClickHouse; в БД не пишет. `ARGS="--gate"` — гейт Stage 1.
cpi-v4-leaderboard:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --python 3.12 python3 models/cpi/cpi_v4_leaderboard.py $(ARGS)

cpi-v4-leaderboard-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --python 3.12 python3 models/cpi/cpi_v4_leaderboard_test.py -v

# #396 Task 5: сетка 3 таргета × h1/h3/h6 (эксперимент 1). `ARGS="--sample S_L09"`,
# `--quick` — только итерации, `--cells T_NSA:1`. `ML_LOG=1` — паспорт (cpi_v4).
cpi-v4-grid:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --python 3.12 python3 models/cpi/cpi_v4_grid.py $(ARGS)

cpi-v4-grid-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --python 3.12 python3 models/cpi/cpi_v4_grid_test.py -v

# #502: H2O AutoML как генератор challenger'а для CPI v4. Селектор видит
# только до-тестовые origin'ы (O + h <= 2015-12), затем frozen refit в том же
# walk-forward, что сетка v4; gate — build/ml-gate/cpi_v4_h2o.{json,md}.
# Нужен JDK 8–17 (H2O 3.46): brew install openjdk@17.
H2O_JAVA_HOME ?= $(shell brew --prefix openjdk@17 2>/dev/null)
cpi-v4-h2o:
	@test -x "$(H2O_JAVA_HOME)/bin/java" || { echo "JDK 8–17 не найден: brew install openjdk@17"; exit 1; }
	@$(MLFLOW_PREFLIGHT)
	JAVA_HOME="$(H2O_JAVA_HOME)" PATH="$(H2O_JAVA_HOME)/bin:$$PATH" \
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "h2o==3.46.0.12" --with "catboost>=1.2" --with pandas --with numpy --with scikit-learn --with "statsmodels>=0.15" --with scipy --with arch --python 3.12 python3 models/cpi/cpi_v4_h2o.py $(ARGS)

cpi-v4-h2o-test:
	uv run --with "catboost>=1.2" --with pandas --with numpy --with scikit-learn --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_v4_h2o_test.py -v

# Issue #396 Task 3: core_nnls (NNLS-веса по 14 корзинам панели #364, as-of) и
# модели v4c/v4d для T_CORE. Диагностика читает CSV панели и ClickHouse.
cpi-core-nnls:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_core_nnls.py $(ARGS)

cpi-core-nnls-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_core_nnls_test.py -v

# Issue #396 Task 6: решение gate эксперимента 2 (H2) по ячейкам cpi-v4-grid;
# читает build/cpi-v4/, пишет build/ml-gate/cpi_v4_h2.{json,md}; без сети и БД.
cpi-v4-h2:
	uv run --with numpy --with scipy --with arch --with pandas --python 3.12 python3 models/cpi/cpi_v4_h2.py $(ARGS)

cpi-v4-h2-test:
	uv run --with numpy --with scipy --with arch --with pandas --python 3.12 python3 models/cpi/cpi_v4_h2_test.py -v

# Issue #396 Task 7: эксперимент 3 (H3) — v4c/v4d на T_CORE, B0f/M1f, решение gate.
# Читает ClickHouse и CSV панели #364; пишет build/cpi-v4/core_*/ и build/ml-gate/cpi_v4_h3.*.
cpi-v4-core:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_v4_core.py $(ARGS)

cpi-v4-core-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_v4_core_test.py -v

cpi-sa-reconciliation:
	uv run --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_sa_reconciliation.py $(ARGS)

cpi-sa-reconciliation-test:
	uv run --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_sa_reconciliation_test.py

cpi-asof-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_asof_test.py && python3 models/cpi/cpi_release_dates_test.py

cpi-weekly-sa-asof:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/weekly_sa_asof.py $(ARGS)

cpi-weekly-sa-asof-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/weekly_sa_asof_test.py

cpi-two-stage-targets-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_targets_test.py

cpi-two-stage-folds:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_folds.py $(ARGS)

cpi-two-stage-s1:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_s1.py $(ARGS)

cb-comp-data-reconcile:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cb_comp_data_reconcile.py $(ARGS)

cpi-two-stage-cb-comp:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_cb_comp.py $(ARGS)

cpi-two-stage-cb-comp-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_cb_comp_test.py

cb-comp-data-reconcile-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cb_comp_data_reconcile_test.py

cpi-two-stage-s1-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_s1_test.py

cpi-two-stage-folds-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_folds_test.py

cpi-two-stage-w2:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_w2.py $(ARGS)

cpi-two-stage-w2-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cpi/cpi_two_stage_w2_test.py

# Issue #364: core-прокси ИПЦ из недельных компонент 2021+ и короткие модели
# (M1 raw, M2 Fourier-OLS, M3 UCM, M4 ridge-бридж, M5 seasonal naive).
# Читает CSV-панель и ClickHouse, в БД не пишет; JSON — docs/research/.
weekly-core-components:
	uv run --with "statsmodels>=0.15" --with numpy --with scipy --with "holidays>=0.60" --python 3.12 python3 models/cpi/weekly_core_components.py $(ARGS)

weekly-core-components-test:
	uv run --with "statsmodels>=0.15" --with numpy --with scipy --with "holidays>=0.60" --python 3.12 python3 models/cpi/weekly_core_components_test.py -v

# Task 3 #236: недельная компонентная панель ИПЦ — месячный m/m товаров,
# реконструкция food/nonfood/services, покрытие весов и гейт bottom-up.
# Читает ClickHouse, в БД не пишет; артефакты — docs/research/.
cpi-weekly-panel:
	uv run --with openpyxl --python 3.12 python3 models/cpi/cpi_weekly_component_panel.py $(ARGS)

cpi-weekly-panel-test:
	uv run --with openpyxl --python 3.12 python3 models/cpi/cpi_weekly_component_panel_test.py -v

# Конвейер CPI → SA → ставка (#309): календарь публикаций, stage 1, real-time SA,
# stage 2. Gate 2 FAIL — stage 3 не строился; в forecast_log не пишется.
publication-calendar-test:
	uv run --python 3.12 python3 bi_ml/publication_calendar_test.py -v

cpi-pipeline-stage1:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_pipeline_stage1.py $(ARGS)

cpi-pipeline-stage1-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_pipeline_stage1_test.py -v

cpi-pipeline-sa-test:
	uv run --with "statsmodels>=0.15" --with pandas --with scipy --python 3.12 python3 models/cpi/cpi_pipeline_sa_test.py -v

cpi-pipeline-stage2:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_pipeline_stage2.py $(ARGS)

cpi-pipeline-stage2-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cpi/cpi_pipeline_stage2_test.py -v

# T4 #279: одноразовый экспорт полной панели весов КИПЦ (52 кода/476 строк)
# из Vesa-tov-KIPC_2012-2026.xlsx; требует openpyxl (как T3), в CH не пишет.
ppi-sa-weights-panel:
	uv run --with openpyxl --python 3.12 python3 models/ppi_sa/ppi_sa_weights_panel.py

ppi-sa-weights-panel-test:
	uv run --with openpyxl --python 3.12 python3 models/ppi_sa/ppi_sa_weights_panel_test.py -v

# T4 #279: паритет ppi_sa с 10 текстовыми якорями «Инфляции в России».
# Читает ClickHouse read-only (через bi_ml/clickhouse.py), в БД не пишет;
# JSON — docs/research/2026-10-21-ppi-sa-parity.json. Цель ±0,3 п.п. может быть
# не достигнута — отчёт публикует расхождение, а не подгоняет веса.
ppi-sa-parity:
	$(RUN) python3 models/ppi_sa/ppi_sa_parity.py

ppi-sa-parity-test:
	$(RUN) python3 models/ppi_sa/ppi_sa_parity_test.py -v

# T3/T4: сверка ppi_sa с текстовыми якорями 12 выпусков «Инфляции в России»
# (2025-10…2026-09). Точные числа — где они есть; качественные формулировки —
# отдельный класс проверок. Читает ClickHouse read-only, пишет CSV/JSON в docs/research/.
ppi-sa-text-anchors:
	$(RUN) python3 models/ppi_sa/ppi_sa_text_anchors.py --print

ppi-sa-text-anchors-test:
	$(RUN) python3 models/ppi_sa/ppi_sa_text_anchors_test.py -v

# Task 1 #317: research-only отраслевой ИЦП, официальные XLSX 08-2026, без ClickHouse.
ppi-sa-industry:
	uv run --with openpyxl==3.1.5 --python 3.12 python3 models/ppi_sa/ppi_sa_industry.py --print

ppi-sa-industry-test:
	uv run --with openpyxl==3.1.5 --python 3.12 python3 models/ppi_sa/ppi_sa_industry_test.py -v

# Task 2 #318: research-only direct h1/h3/h6 прогноз CPI/PPI с aggregate
# ценовыми ожиданиями и парными B2/B3 без ожиданий. Читает ClickHouse
# read-only, пишет локальные Markdown/JSON/CSV; ML_LOG=1 — паспорт и folds,
# без registry/promote и без forecast_log. Официальный прогон:
# make ppi-monthly-forecast ARGS="--out-dir docs/research"
ppi-monthly-forecast:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with numpy --with pandas --with scikit-learn --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/ppi/ppi_monthly_forecast.py $(ARGS)

ppi-monthly-forecast-test:
	uv run --with numpy --with pandas --with scikit-learn --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/ppi/ppi_monthly_forecast_test.py -v

# Live-диагностика per_sheet: экспорт v_cbr_mp_public_panel (87 кодов × 3
# индикатора, но 33 различные серии) и v_cbr_mp_bsu_map (код → industry_slug)
# в build/cb-comp-parity. Только чтение ClickHouse.
cb-comp-public-export:
	uv run --with pandas --python 3.12 python3 models/cb_comp/cb_comp_public_export.py --out-dir build/cb-comp-parity

# Паритет ML-трека с CB_COMP (issue #190): таргет TARGET_FULL из архива авторов,
# архивные per-period прогнозы CB_COMP, две CatBoost-direct модели (с МП/без МП),
# DM-HLN, TOST с margin 10% RMSE CB_COMP, RMSE ratio. Архив не скачивается:
# путь — --archive или CB_COMP_ARCHIVE (по умолчанию worktree-сосед cb-comp-archive).
# Читает ClickHouse (ряды v2), пишет локальные артефакты; в ClickHouse не пишет.
cb-comp-parity:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_parity.py $(ARGS)

# Офлайн-тесты parity-скрипта: без ClickHouse и без архива.
cb-comp-parity-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_parity_test.py -v
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_bottomup_test.py -v

# Task 1 #421: live-панель 88 групп CB_COMP из ЕМИСС 31074 (v_fedstat_ipc) —
# маппинг, NSA, X-13 по группам (R seasonal), сборка против TARGET_FULL.
# Только чтение ClickHouse и локального архива CB_COMP; в БД не пишет.
cb-comp-groups-panel:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_groups_panel.py $(ARGS)

cb-comp-groups-panel-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_groups_panel_test.py -v

# Task 2 #422: live bottom-up по 88 группам на нашей панели, цель T_LIVE —
# R0 (регрессия #252), G2, сравнение с CB_COMP «каждый на своей цели».
# Нужны артефакты make cb-comp-groups-panel ARGS="--asof" и make cb-comp-public-export.
# ML_LOG=1 — паспорт и fold-предсказания (P0.5); MLFLOW=0 — осознанно выключить.
cb-comp-live-bottomup:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_live_bottomup.py $(ARGS)

cb-comp-live-bottomup-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_live_bottomup_test.py -v
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --python 3.12 python3 models/cb_comp/cb_comp_mlog_test.py -v

# Task 3 #423: EN_COMP и CB+EN на нашей панели, истина TARGET_FULL —
# классификация против CB_COMP, MCS, выбор модели, гейт G3 (спека §15).
cb-comp-live-en:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_live_en.py $(ARGS)

cb-comp-live-en-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_live_en_test.py -v

# Task 9 #436: h1 — комбинация live_cb + BS_ECON16/BS_ROZN16 статьи (OLS на
# T_LIVE и SA ценовых ожиданиях ЦБ, окно 2016+, переобучение без утечки).
# ML_LOG=1 — паспорт run'а в ml_runs/ml_predictions и MLflow (P0.5);
# MLFLOW=0 — осознанно выключить.
cb-comp-h1-bs-combo:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_h1_bs_combo.py $(ARGS)

cb-comp-h1-bs-combo-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h1_bs_combo_test.py -v
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --python 3.12 python3 models/cb_comp/cb_comp_mlog_test.py -v

# P0.4 #25: сверка live-весов ИПЦ (v_rosstat_cpi_weights) с архивом CB_COMP
# 2016–2024, суммы 2025–26 и покрытие; в БД не пишет.
cb-comp-weights-check:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_weights_check.py $(ARGS)

cb-comp-weights-check-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_weights_check_test.py -v

# Task 17 #501: CatBoost vs LightGBM/XGBoost на том же конвейере Task 9 —
# плечи defaults/matched, точность (RMSE/ratio/DM/CI/MCS) и время fit;
# ML_LOG=1 — паспорта в эксперименте cb_comp_88_groups (MLflow + ml_runs).
# Входы — как у cb-comp-h1-bs-combo; в ClickHouse не пишет.
cb-comp-backend-compare:
	@$(MLFLOW_PREFLIGHT)
	$(MLFLOW_ENV) $(MLFLOW_HTTP_ENV) uv run $(MLFLOW_PKG) --with "catboost==1.2.10" --with "lightgbm==4.7.0" --with "xgboost==3.4.1" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_backend_compare.py $(ARGS)

cb-comp-backend-compare-test:
	uv run --with "catboost==1.2.10" --with "lightgbm==4.7.0" --with "xgboost==3.4.1" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_backend_compare_test.py -v

# Task 10 #438: pooled CatBoost на 87 группах (окно 2016+ / control 2010-03+),
# годовая переподготовка без утечки; G10 против combo3, MCS 90 %.
# Входы — как у cb-comp-h1-bs-combo.
cb-comp-pooled:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_pooled.py $(ARGS)

cb-comp-pooled-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_pooled_test.py -v

# Task 5 #425: режим переобучения live_cb — frozen / annual / annual_shock /
# annual_dummy / rolling96 / rolling120, шоки (2014-12…2015-03, 2020-04, 2022)
# в train и гипотеза W5b (месячный wf на live_cb + прямой тест v3/v5_direct).
# Входы — как у cb-comp-h1-bs-combo; W5b-диагностике нужны R seasonal и ClickHouse.
# Только чтение ClickHouse и локального архива CB_COMP; в БД не пишет.
cb-comp-refit-modes:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_refit_modes.py $(ARGS)

cb-comp-refit-modes-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --python 3.12 python3 models/cb_comp/cb_comp_refit_modes_test.py -v

# Task 4 #424: h1 — недельный ИПЦ поверх combo3: маппинг 148 недельных позиций
# на 88 групп, wk_g_* в live_cb, смешивание с недельным агрегатом, walk-forward
# 2022+ (ежемесячный expanding) и G10/Holm. Только чтение ClickHouse и архива.
cb-comp-h1-weekly:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_h1_weekly.py $(ARGS)

cb-comp-h1-weekly-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_weekly_groups_test.py -v
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h1_weekly_test.py -v

# Task 4b #446: h1 — недельный агрегат без ЖКУ (9470) и с месячными дамми поверх
# combo3; база — готовые прогнозы Task 4 (predictions.csv), G11 на 2023+.
# Только чтение ClickHouse и локального архива CB_COMP; в БД не пишет.
cb-comp-h1-weekly-ex:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_h1_weekly_ex.py $(ARGS)

cb-comp-h1-weekly-ex-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h1_weekly_ex_test.py -v

# P0.6 #453: paper shadow wk_mix_ex@v1 (гайд cb-comp-live-model-map §7.8).
# robustness — 2023-01…2026-09 на входах Task 4b (R-P0, publication, real-time
# SA, тарифы, bias, недельные срезы, fallback); forecast — прогноз месяца
# MONTH=YYYY-MM со свежей МП-панелью в build/cb-comp-h1-shadow/public и JSON в
# docs/research/cb-comp-h1-shadow/. Только чтение ClickHouse и архива.
CB_COMP_SHADOW_UV = uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3
cb-comp-h1-shadow-robustness:
	$(CB_COMP_SHADOW_UV) models/cb_comp/cb_comp_h1_shadow.py robustness $(ARGS)

cb-comp-h1-shadow-forecast:
	@test -n "$(MONTH)" || (echo "MONTH=YYYY-MM обязателен" && exit 1)
	uv run --with pandas --python 3.12 python3 models/cb_comp/cb_comp_public_export.py --out-dir build/cb-comp-h1-shadow/public
	$(CB_COMP_SHADOW_UV) models/cb_comp/cb_comp_h1_shadow.py forecast --month $(MONTH) --public-dir build/cb-comp-h1-shadow/public $(ARGS)

# Решение владельца 2026-10-31 (#419): ежемесячно — засчитываемый v2 (@2009,
# docs/research/cb-comp-h1-shadow-2009/) и контроль v1 (@2010) на тех же входах.
cb-comp-h1-shadow-forecast-v2:
	@test -n "$(MONTH)" || (echo "MONTH=YYYY-MM обязателен" && exit 1)
	$(MAKE) cb-comp-h1-shadow-forecast MONTH=$(MONTH) ARGS="--version 2009 $(ARGS)"
	$(MAKE) cb-comp-h1-shadow-forecast MONTH=$(MONTH) ARGS="--version 2010 $(ARGS)"

cb-comp-h1-shadow-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h1_shadow_test.py -v
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h1_p06_versions_test.py -v

# Task 16 #466: P0.6 по версиям цели @2010/@2009 — матрица 2×2 (прогнозы ×
# истины), Δ версий и правило смены базы цели. Читает готовые
# predictions_robustness.csv (`cb-comp-h1-shadow-robustness ARGS="--version …"`).
cb-comp-h1-p06-versions:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h1_p06_versions.py $(ARGS)

# P0.6a #462: MLflow-зеркало shadow-JSON месяца (experiment cb_comp_h1_shadow,
# run на month+json_sha256). Канонический backend — staging MLflow, не локальный
# build/mlflow: URI обязателен (MLFLOW_TRACKING_URI или ARGS="--tracking-uri ...");
# --dry-run работает без URI. Читает docs/research/cb-comp-h1-shadow/*.json,
# в ClickHouse не пишет; backfill — ARGS="--backfill".
cb-comp-h1-shadow-mlflow:
	@if [ -z "$(MLFLOW_TRACKING_URI_EXPLICIT)" ] && ! printf '%s' "$(ARGS)" | grep -Eq -- '--tracking-uri|--dry-run'; then \
		echo "MLflow tracking URI не задан: канонический backend — staging, не локальный build/mlflow."; \
		echo "  MLFLOW_TRACKING_URI=http://192.168.3.9:5000 make cb-comp-h1-shadow-mlflow ARGS=\"--backfill\""; \
		echo "  fallback: ssh -N -L 15001:127.0.0.1:5000 palmshell"; \
		echo "  MLFLOW_TRACKING_URI=http://127.0.0.1:15001 make cb-comp-h1-shadow-mlflow ARGS=\"--backfill\""; \
		echo "  или ARGS=\"--tracking-uri http://192.168.3.9:5000\""; \
		echo "  локальный 127.0.0.1:5000 — только dev/офлайн-тесты"; \
		exit 1; \
	fi
	$(MLFLOW_HTTP_ENV) uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 \
		python3 models/cb_comp/cb_comp_h1_shadow_mlflow.py \
		$(if $(MLFLOW_TRACKING_URI_EXPLICIT),--tracking-uri $(MLFLOW_TRACKING_URI),) $(ARGS)

cb-comp-h1-shadow-mlflow-test:
	uv run --with "mlflow==$(MLFLOW_VERSION)" --python 3.12 python3 models/cb_comp/cb_comp_h1_shadow_mlflow_test.py -v

# Task 12 #440: h3/h6 — агрегатный VAR/BVAR по ИПЦ SA без КУ, ставке, USD/руб
# и SA ценовым ожиданиям (окно 2016+, BIC-лаг, помесячное переобучение) и
# комбинация combo3 + var16; R12, гейт G12. Только чтение ClickHouse и архива.
cb-comp-h3-h6-var:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_h3_h6_var.py $(ARGS)

cb-comp-h3-h6-var-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_h3_h6_var_test.py -v

# P0.3 #480: живая цель T_LIVE 2024-08+ — правило пропусков renorm_v1,
# покрытие весов/групп по месяцам, альтернатива T_LIVE_direct (X-13 на
# NSA-агрегате), NSA-проверка весов против публикуемого ИПЦ и append-only
# снимок цели. Только чтение ClickHouse и архива CB_COMP; в БД не пишет.
cb-comp-tlive-target:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_tlive_target.py $(ARGS)

cb-comp-tlive-target-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_tlive_target_test.py -v

# Task 7 #427: итоговый gate линии 88 групп — классы §6.3 против CB_COMP на
# normal-54/67, MCS 90 %, пины Task 9 и справочные режимы Task 5
# (ARGS="--refit-predictions build/cb-comp-refit-modes/predictions.csv"), плюс
# paper shadow 2024-08…2026-09 на as-of входах (T_LIVE_rt/T_LIVE, SA ЦБ, B1).
# Артефакт — build/ml-gate/cb_comp_88_live.{json,md}; в ClickHouse не пишет.
cb-comp-88-live-gate:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_88_live_gate.py $(ARGS)

cb-comp-88-live-gate-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_88_live_gate_test.py -v

# Task 11 #439: h3 — EN по 88 группам с окном 2016+ и помесячным переобучением,
# combo4 = среднее combo3 и live_en16; R11, гейт G11 (спека).
cb-comp-live-en16:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --with arch --with "holidays>=0.60" --python 3.12 python3 models/cb_comp/cb_comp_live_en16.py $(ARGS)

cb-comp-live-en16-test:
	uv run --with "catboost>=1.2" --with scikit-learn --with pandas --with openpyxl --with "statsmodels>=0.15" --with scipy --python 3.12 python3 models/cb_comp/cb_comp_live_en16_test.py -v

# Разбор PR #435 (research 2026-10-31): per-code МП, гармонизация SA, разрыв h1.
# Шаги: ARGS="--step distinct|forward|inverse|noise|priors|sa-inputs|sa-compare|panels|dm".
# Входы — build/cb-comp-parity (архив per-code + публичная панель) и книги ЦБ
# (cb-comp-per-code-review-books); X-13 — cb-comp-per-code-review-x13 (R seasonal).
# Только локальные файлы; в ClickHouse не пишет.
CB_COMP_REVIEW_DIR := build/cb-comp-per-code-review
cb-comp-per-code-review:
	uv run --with pandas --with numpy --with scipy --with openpyxl --python 3.12 python3 models/cb_comp/cb_comp_per_code_review.py $(ARGS)

cb-comp-per-code-review-test:
	uv run --with pandas --with numpy --with scipy --with openpyxl --python 3.12 python3 models/cb_comp/cb_comp_per_code_review_test.py -v

cb-comp-per-code-review-books:
	mkdir -p $(CB_COMP_REVIEW_DIR)/books
	for f in 135603/mp_survey_data.xlsx 162126/survey_data_group.xlsx 178789/mp_survey_data_gu.xlsx; do \
		curl -fsS --retry 3 -A "Mozilla/5.0" -o $(CB_COMP_REVIEW_DIR)/books/$$(basename $$f) https://www.cbr.ru/Content/Document/File/$$f || exit 1; \
	done

cb-comp-per-code-review-x13:
	Rscript models/cb_comp/cb_comp_per_code_review_x13.R $(CB_COMP_REVIEW_DIR)/sheets_nsa_sa.csv $(CB_COMP_REVIEW_DIR)/sheets_x13.csv

# Task 8 #434 (research): восстановление per-code МП (87 кодов) из листовых агрегатов
# обратной задачей — forward-оператор W, rank/null-space, методы identity/offset/
# ridge/factor/omp/coord/elim; гейты G-R1/G-R2 (спека §16). Только чтение локальных
# файлов: panel.csv + public_panel.csv/sheet_map.csv из build/cb-comp-parity.
cb-comp-per-code-reconstruction:
	uv run --with pandas --with numpy --python 3.12 python3 models/cb_comp/cb_comp_per_code_reconstruction.py $(ARGS)

cb-comp-per-code-reconstruction-test:
	uv run --with pandas --with numpy --python 3.12 python3 models/cb_comp/cb_comp_per_code_reconstruction_test.py -v

# Прокси-путь CB_COMP (issue #190): SA ИПЦ без КУ из публичных рядов ЦБ/Росстата
# и RMSE нашего месячного nowcast на окне статьи 2019-01…2024-07. Читает ClickHouse,
# в ClickHouse не пишет. Нужен CSV месячного трека v2 (--nowcast-csv), который
# создаётся `make cpi-monthly ARGS="--sample long"` в ветке feat/key-rate-ml-v2.
cb-comp-proxy:
	uv run --with pandas --with scipy --with "statsmodels>=0.15" --python 3.12 python3 models/cb_comp/cb_comp_proxy.py $(ARGS)


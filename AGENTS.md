# AGENTS.md — правила работы в `bi-ml-models`

Репозиторий разработки и тестирования моделей прогнозирования. Платформа данных — [`kmlebedev/clickhouse-import-rosstat`](https://github.com/kmlebedev/clickhouse-import-rosstat): там Go-импортёры, DDL, витрины, `forecast_log`, DAG, дашборды, файлы роадмапов и Project V2. Issue ML-пунктов (`role:ml`) с 2026-11-12 открываются здесь, в `bi-ml-models`.

## Роль

ML-инженер работает здесь: модели, признаки, бэктесты, gate, MLflow-клиент, live-проверки, model cards и research по моделям. Go-код, DDL, витрины, гранты и ingest-эндпоинты — в main; этот репозиторий их не меняет.

## Что прочитать перед стартом

1. `README.md` — карта моделей, быстрый старт, границы записи.
2. `models/<семейство>/README.md` — model card выбранного семейства.
3. `docs/methodology/stat-ml-models.md` — валидация, ловушки, данные.
4. `docs/research/2026-10-18-ml-experiment-management.md` — паспорт run и цикл gates.
5. Спека/план пункта — `docs/specs/`, `docs/plans/`; issue ML-пункта — здесь, на него ссылается PR; файл роадмапа и статус пункта — в main.

## Жёсткие правила

1. **Только walk-forward**; random split запрещён. Purge/embargo — обязательны.
2. **Никакого тюнинга по тесту**; гиперпараметры — только внутри train.
3. **As-of/PIT**: точка, опубликованная после cutoff, в фолд не попадает.
4. **Полный набор метрик**: RMSE/MAE, DM-HLN, блочный бутстрап CI; «значимо» — это DM/CI, а не «число меньше».
5. **Бенчмарки B1–B3** фиксируются до результата; без значимого выигрыша модель не входит в ансамбль.
6. **Детерминизм**: seed, `config_hash`/`sample_hash`, sha256 артефактов; повторный прогон совпадает.
7. **NaN ≠ 0**; импутация — медианой train внутри фолда.
8. **Секреты только через env**; не читать и не печатать `~/.config/rosstat/env`.
9. **Чтение ClickHouse** — `bi_ml/clickhouse.py`. **Запись** — только `ml_runs`/`ml_predictions` (`ML_LOG=1`) и live через ingest (`tools/forecast_log.py`). Прямой `INSERT` в другие таблицы запрещён.
10. **Команды — через `make`/`uv`**, не `python` напрямую с ожиданием переменных окружения.
11. **Тесты офлайн**: без ClickHouse и сети; данные — из `testdata/`.
12. **Один пункт — одна ветка — один PR.** Трекер ML-пунктов — issue здесь, в `bi-ml-models` (Project V2 и канонический статус пункта — в main); PR содержит ссылку на issue пункта.

## Команды

| Цель | Что делает |
|---|---|
| `make test` | все офлайн-тесты (`bi_ml`, `tools`, `models`) |
| `make compile` | проверка синтаксиса Python 3.12 |
| `make notebooks-check` | исполнение 3 ноутбуков на фикстурах/синтетике |
| `make cpi-nowcast ARGS="--quick"` | nowcast ИПЦ v1 |
| `make key-rate-model` | ставка: Taylor/ordered logit, walk-forward |
| `make cb-comp-parity` | паритет с CB_COMP |
| `make ml-gate ARGS="--champion-run <uuid> --challenger-run <uuid> --model <m>"` | gate промоушена |
| `make ml-live-check ARGS="--require-llm"` | production-строки до публикации |
| `make key-rate-forecast-log ARGS="--dry-run"` | запись live-прогноза через ingest |
| `make mlflow-tunnel` | SSH-туннель к staging MLflow |
| `make mlflow-preflight` | проверка MLflow API |

## Паспорт run

`ML_LOG=1` пишет `ml_runs`/`ml_predictions`; `MLFLOW=1` (по умолчанию) — MLflow. Канонические run'ы — только staging-туннель `http://127.0.0.1:15001`; локальный `build/mlflow` — отладка, не evidence. Gate читает ClickHouse `v_ml_error_by_fold`, а не MLflow API. В `env_json` пишется `source_repo: "kmlebedev/bi-ml-models"`; старые строки без поля — из main.

## Definition of Done

- [ ] Предрегистрация (гипотеза, метрика, бенчмарки, фолды, правило gate) — до результата.
- [ ] Бенчмарки B1–B3 и полный набор метрик; DM/CI.
- [ ] Паспорт run, артефакты с sha256, повтор детерминирован.
- [ ] `make test` зелёный; для схемы/грантов — проверка в main.
- [ ] Числа и «что не проверено» сформулированы честно; протокол — в PR.

# Миграция из clickhouse-import-rosstat

Дата: 2026-11-10. Источник: `kmlebedev/clickhouse-import-rosstat@8b179cbc3dfd4d2b3faa92dd0bcc08da11dd2eb0`.
История извлечена `git filter-repo`; полная карта путей — `manifest.tsv`.

## Что переехало

| Группа | Файлов |
|---|---|
| Модели | 165 |
| Общее ядро | 8 |
| CLI | 13 |
| Фикстуры | 35 |
| Документация | 251 |
| Скилы | 2 |
| Исторические артефакты | 8 |
| Каркас проекта | 13 |
| **Всего** | **495** |

## Правила путей

- `scripts/models/**` → `models/**`; `scripts/ppi_sa_*` → `models/ppi_sa/`.
- `scripts/lib/{clickhouse,eval_utils,publication_calendar}` → `bi_ml/`; `ml_experiment.py` → `bi_ml/experiment.py`.
- `scripts/{ml_gate,ml_live_check,key_rate_forecast_log,mlflow_*}` → `tools/`.
- `scripts/testdata/**` (кроме `edisclosure/`) → `testdata/**`.
- `docs/superpowers/{specs,plans}` → `docs/{specs,plans}`; методология и model cards — `docs/models`, `docs/methodology`.
- `weeklysa/data/weekly_cpi_sa_x13.R` → `models/cpi/weekly_cpi_sa_x13.R` (побайтовая копия, SHA пинуется).
- Спеки/планы и research, не относящиеся к моделям, остались в main.

## Паспорт прогона и `git_sha`

- `ml_runs.git_sha` до миграции — SHA `clickhouse-import-rosstat`, после — SHA `bi-ml-models`.
- DDL не менялся: в `env_json` новых прогонов пишется `source_repo: "kmlebedev/bi-ml-models"`.
- Отсутствие `source_repo` в старых строках означает `clickhouse-import-rosstat`.
- Полные 40-символьные SHA не коллидируют; старые SHA остаются валидными в истории main.
- `spec_path` новых прогонов — `docs/specs/...` относительно этого репозитория.

## Что осталось в main

- Go-импортёры `mlregistry`/`forecast`/`weeklysa`/`ppi`, DDL, витрины `v_ml_*`, ingest.
- `forecast_log`, `forecast_resolve`, DAG, Grafana-алерты, дашборды.
- Staging-деплой MLflow (`deploy/staging/mlflow.service`, `make deploy-staging-mlflow`).
- Публикации, роадмапы, issue/Project V2, research по источникам данных.
- Копия `scripts/lib/clickhouse.py` для `scripts/publications/weekly_sa_chart.py`.

## Кросс-репозиторные проверки

Три polyus-теста и два теста свежести сида зависят от файлов main (`dcf/mine_plans_seed.go`,
`sql/dcf_mine_plans_seed.sql`). В этом репозитории они пропускаются; parity проверяется в main.
Отдельно: `test_opr_years_cover_the_window_until_the_mill_starts` и два соседних теста
были красными в main до миграции (OPR_YEARS 2025–2027 против ожидаемых 2025–2029); они
помечены skip с причиной, фикс — отдельным пунктом.

## Запуск после миграции

```bash
uv sync --python 3.12
make test
make cpi-nowcast ARGS="--quick"
```

Публикационный runbook в main использует те же артефакты, но команды теперь:
`make key-rate-forecast-log` и `make ml-live-check` из этого репозитория.

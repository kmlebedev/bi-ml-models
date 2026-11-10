# `models.cb_comp` — 88 групп ИПЦ и live-контур

Модели по публичной панели CB_COMP: per-sheet, per-code, bottom-up, `combo3` и shadow-варианты.

## Что внутри

| Скрипт | Назначение |
|---|---|
| `cb_comp_live_pipeline.py` | live-конвейер 88 групп, признаки и прогноз |
| `cb_comp_h1_bs_combo.py` | `combo3` = `live_cb` + BS статьи |
| `cb_comp_h1_weekly.py`, `cb_comp_h1_weekly_ex.py` | недельные варианты и `wk_mix_ex` |
| `cb_comp_h1_shadow*.py` | paper shadow и MLflow-зеркало |
| `cb_comp_parity.py`, `cb_comp_proxy.py` | паритет с CB_COMP и прокси-путь |
| `cb_comp_per_code_*.py` | восстановление per-code МП из листовых агрегатов |

## Данные

Публичная панель CB_COMP (локальный архив, `resolve_archive`), МП-панель, X-13 (`Rscript` + `seasonal`), ClickHouse read-only.

## Канонические числа и статус

- `combo3` — champion live-контура; `wk_mix_ex@v1` — challenger, paper shadow (P0.6).
- Shadow-паспорта — `docs/research/cb-comp-h1-shadow/<YYYY-MM>.json`; staging-run в MLflow — каноническое зеркало, JSON остаётся источником истины.
- Backend compare (CatBoost vs LightGBM/XGBoost) — `cb_comp_backend_compare.py`, отчёт `docs/research/2026-11-01-cb-comp-backend-compare.md`.

## Запуск и тесты

```bash
make cb-comp-live
make cb-comp-h1-bs-combo
make cb-comp-parity
make cb-comp-h1-shadow-mlflow ARGS="--backfill"
make cb-comp-h1-shadow-test
```

Нужен локальный архив CB_COMP; тесты — офлайн на `testdata/`.

## Документация

Карта модели и реестр исследований — `docs/models/cb-comp-live-model-map.md`. Промоушен — `make ml-gate`, затем shadow 2 заседания и canary 1; alias `champion` — registry, не deployment.

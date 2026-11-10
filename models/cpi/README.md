# `models.cpi` — ИПЦ

Месячный и недельный nowcast ИПЦ, компонентные модели и SA-сверки.

## Что внутри

| Скрипт | Назначение |
|---|---|
| `cpi_nowcast.py` | nowcast v1: CatBoost + бенчмарки B1–B3, недельные признаки |
| `cpi_monthly.py` | месячный nowcast v2 с МП |
| `cpi_monthly_v3.py`, `cpi_monthly_industry.py` | Stage 1/2 #76: недельные diffusion-признаки и 16 отраслевых листов |
| `cpi_v4_grid.py`, `cpi_v4_h2.py`, `cpi_v4_core.py`, `cpi_core_nnls.py` | #396: сетка таргетов, gate по `wkagg_*`, NNLS по 14 корзинам |
| `cpi_two_stage_*.py` | #401: двухстадийная схема `T_SAX`/`T_CORE`/`T_NSA` |
| `cpi_sa_reconciliation.py`, `weekly_sa_asof.py`, `weekly_core_*.py` | SA и недельные компоненты |

## Данные

`v_rosstat_macro`, `v_fedstat_*`, `v_cbr_*`, недельные ряды `rosstat_ipc_weeks*`, `weekly_cpi_sa`. Только чтение ClickHouse.

## Канонические числа

- #76 Stage 1 `weekly`: `v3_bottomup` 0,311487 vs `v2_bottomup` 0,362300 (−14,0 %, DM p=0,0285); `long`: 0,642997 vs 0,688869 (p=0,1573) — мощности нет.
- Stage 2 `v3_ind_bottomup` vs `v3_bottomup`: +13,8 %, p=0,3059 — значимого выигрыша нет.
- Покрытие весов публичной панели — **39,3 %** (< 50 %), поэтому полный 88-групповой bottom-up не заявляется; вердикт — `iterate`, не `promote`.

## Запуск и тесты

```bash
make cpi-nowcast ARGS="--quick"
make cpi-monthly-v3 ARGS="--sample weekly"
make cpi-v4-grid ARGS="--sample S_L09 --cells T_NSA:1"
uv run --python 3.12 python3 models/cpi/cpi_nowcast_test.py -v
```

Фикстуры — `testdata/cpi_nowcast/`, `testdata/cpi_monthly/`, `testdata/publication_calendar.csv`. Тесты офлайн.

## Статус

Research: production-v3 не подключён к DAG, пока coverage gate < 50 %. Методология — `docs/methodology/stat-ml-models.md`, спеки — `docs/specs/2026-10-19-cpi-components-public-data-design.md`, `docs/specs/2026-10-28-cpi-v4-weekly-aggregate-core-design.md`.

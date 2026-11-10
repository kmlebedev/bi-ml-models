# Модели

Каждое семейство — отдельный пакет с README (короткая model card), скриптами и офлайн-тестами. Имена пакетов сохранены при миграции: `models.cpi`, `models.cb_comp`, `models.key_rate`, `models.ppi`, `models.ppi_sa`, `models.polyus`.

| Пакет | Назначение | Точка входа |
|---|---|---|
| `cpi` | ИПЦ: nowcast, месячные v2/v3/v4, two-stage, SA-сверки | `cpi_nowcast.py`, `cpi_monthly.py`, `cpi_monthly_v3.py`, `cpi_v4_grid.py` |
| `cb_comp` | 88 групп ИПЦ, `combo3`, per-sheet/per-code, shadow | `cb_comp_live_pipeline.py`, `cb_comp_h1_bs_combo.py` |
| `key_rate` | ставка: Taylor, ordered logit, сценарии, LLM | `key_rate_model.py`, `key_rate_scenario_fan_v3.py` |
| `ppi` | месячный ИЦП с ожиданиями | `ppi_monthly_forecast.py` |
| `ppi_sa` | X-13 SA ИЦП, паритет и якоря | `ppi_sa_parity.py`, `ppi_sa_x13.R` |
| `polyus` | выпуск и AISC | `polyus_output_model.py`, `aisc.py` |

Общие правила: walk-forward без random split, purge/embargo, as-of/PIT, полный набор метрик (RMSE/MAE, DM-HLN, блочный бутстрап), бенчмарки B1–B3 фиксируются до результата. Методология — `docs/methodology/stat-ml-models.md`.

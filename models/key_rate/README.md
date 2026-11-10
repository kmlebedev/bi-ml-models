# `models.key_rate` — ключевая ставка

Прогноз ставки на заседание: правила, ordered logit, сценарный веер, LLM-трек.

## Что внутри

| Скрипт | Назначение |
|---|---|
| `key_rate_model.py` | Taylor-правило и ordered logit, walk-forward |
| `key_rate_cbr_rule.py` | правило ЦБ |
| `key_rate_scenario_fan.py`, `_v2`, `_v3` | сценарный веер |
| `key_rate_cpi_v3_experiment.py` | CPI-компоненты как вход ставки |
| `key_rate_llm_forecast.py` | LLM-трек: as-of, 3 повтора, медиана |
| `shock_classifier.py` | классификатор шоков и причинные веса |

## Данные

`v_cbr_*`, `v_rosstat_macro`, `v_events_calendar`, новостной слой. Только чтение ClickHouse.

## Live-контур

- Треки: `cbr_rate:taylor`, `cbr_rate:ordered_logit`, `cbr_rate:ml`, `cbr_rate:llm`; ошибка — `error_bp`.
- Запись — только через ingest: `make key-rate-forecast-log` (`POST /v1/key_rate_forecast`), стадии `--stage shadow|canary`.
- Перед публикацией — `make ml-live-check`; после заседания — `forecast_resolve` на стороне платформы.

## Запуск и тесты

```bash
make key-rate-model
make key-rate-scenario-fan-v3
make key-rate-forecast-log ARGS="--dry-run"
uv run --python 3.12 python3 models/key_rate/key_rate_model_test.py -v
```

## Статус

Production-треки `taylor`/`ordered_logit`; LLM — cross-check, не заменяет статистический трек. Registry для key-rate пока нет: промоушен — решение gate + `--stage`, alias `champion` не применяется. Методология — `docs/models/key-rate.md`, каналы — `docs/models/key-rate-channels.md`.

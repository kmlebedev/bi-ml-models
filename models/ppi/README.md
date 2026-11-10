# `models.ppi` — ИЦП

Месячный прогноз ИЦП с агрегированными ценовыми ожиданиями и парными бенчмарками.

## Что внутри

- `ppi_monthly_forecast.py` — direct h1/h3/h6 прогноз CPI/PPI с ожиданиями и без них (B2/B3).
- Пишет локальные Markdown/JSON/CSV; `ML_LOG=1` — паспорт и folds. Registry/promote и `forecast_log` не используются.

## Данные

`v_rosstat_ppi`, ожидания ЦБ; только чтение ClickHouse.

## Запуск и тесты

```bash
make ppi-monthly-forecast
make ppi-monthly-forecast-test
```

## Статус

Research. Отчёт — `docs/research/2026-10-21-ppi-expectations-forecast.md`.

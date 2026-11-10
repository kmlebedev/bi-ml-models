# `models.polyus` — выпуск и AISC Полюса

Модель производственного профиля и удельных затрат Полюса — вход DCF-модели платформы (`dcf/`).

## Что внутри

- `polyus_output_model.py` — сценарный выпуск по активам и запускам ЗИФ (Сухой Лог и др.).
- `aisc.py` — экстраполяция AISC.

## Данные

`polyus_ir`, план производства, исторические отчёты; локальные CSV/PDF. В ClickHouse не пишет.

## Запуск и тесты

```bash
make polyus-output
uv run --python 3.12 python3 models/polyus/polyus_output_model_test.py -v
```

## Статус

Research; числа используются как вход DCF, а не как самостоятельный прогноз. План — `docs/plans/polyus-output-model.md`.

# bi-ml-models

Разработка, бэктесты и тестирование моделей прогнозирования. Репозиторий отвечает на вопрос «какая модель лучше на исторических данных и можно ли её продвигать», но не владеет продакшен-данными.

Платформа данных — [`kmlebedev/clickhouse-import-rosstat`](https://github.com/kmlebedev/clickhouse-import-rosstat): Go-импортёры, схема `ml_runs`/`ml_predictions`, журнал `forecast_log`, резолвер `forecast_resolve`, витрины `v_ml_*`, DAG и дашборды. Здесь — Python-код моделей, офлайн-тесты, gate, MLflow-клиент и документация по моделям.

## Карта моделей

| Семейство | Что прогнозирует | Вход | Команда | Статус |
|---|---|---|---|---|
| `cpi` | ИПЦ: nowcast v1, месячный v2, компоненты v3 (#76), сетка v4 (#396), two-stage (#401) | `v_rosstat_macro`, `v_fedstat_*`, `v_cbr_*`, недельные ряды | `make cpi-nowcast`, `make cpi-monthly`, `make cpi-v4-grid` | research; покрытие весов 39,3 % — production-v3 не заявлен |
| `cb_comp` | 88 групп ИПЦ, `combo3` и `wk_mix_ex`, per-sheet/per-code | публичная панель CB_COMP, МП, X-13 | `make cb-comp-live`, `make cb-comp-h1-bs-combo` | `combo3` — champion live-контура; `wk_mix_ex` — challenger, paper shadow |
| `key_rate` | ставка ЦБ: `taylor`, `ordered_logit`, `scenario_fan`, `cbr_rule`, LLM-трек | `v_cbr_*`, `v_rosstat_macro`, новости | `make key-rate-model`, `make key-rate-forecast-log` | production-треки `cbr_rate:taylor`/`:ordered_logit` через `forecast_log` |
| `ppi` | месячный ИЦП с ценовыми ожиданиями | `v_rosstat_ppi`, ожидания ЦБ | `make ppi-monthly-forecast` | research |
| `ppi_sa` | сезонная корректировка ИЦП (X-13), паритет и якоря | `v_rosstat_ppi`, выпуски «Инфляции в России» | `make ppi-sa-parity` | research/parity для Go-импортёра `ppi_sa` |
| `polyus` | выпуск и AISC Полюса | `polyus_ir`, план производства | `make polyus-output` | вход DCF-модели, research |

Подробности по каждому семейству — в `models/<семейство>/README.md`. Методология — `docs/methodology/stat-ml-models.md`, карта live-контура 88 групп — `docs/models/cb-comp-live-model-map.md`.

## Быстрый старт

```bash
uv sync --python 3.12
make test                      # офлайн: без ClickHouse и сети
make compile                   # проверка синтаксиса
```

Живой прогон требует `CLICKHOUSE_URL` (обычно из `~/.config/rosstat/env`) и читает ClickHouse только на чтение:

```bash
make cpi-nowcast ARGS="--quick"
make key-rate-model
make cb-comp-parity
```

Ноутбуки — учебные, на фикстурах и синтетике:

```bash
uv sync --extra notebooks --python 3.12
make notebooks-check
```

## Данные и границы записи

- **Чтение** — ClickHouse HTTP-клиент `bi_ml/clickhouse.py`; те же env-переменные, что у платформы (`CLICKHOUSE_URL`, `CLICKHOUSE_PASSWORD`).
- **Запись** — только две вещи: паспорт прогона `ml_runs`/`ml_predictions` (`ML_LOG=1`) и live-прогноз через ingest-контур (`POST /v1/key_rate_forecast`, `make key-rate-forecast-log`). Прямой `INSERT` в другие таблицы запрещён: схема принадлежит платформе.
- **Секреты** — только через env; не коммитить и не печатать.
- **Детерминизм** — `config_hash`/`sample_hash`, seed, sha256 артефактов; повторный прогон должен совпасть.

## MLflow

MLflow — control plane экспериментов. Канонические прогоны — только staging через SSH-туннель:

```bash
make mlflow-tunnel             # ssh -N -L 15001:127.0.0.1:5000 palmshell
make mlflow-preflight
make cpi-nowcast ML_LOG=1      # MLFLOW=1 по умолчанию
```

Локальный сервер (`make mlflow-up`) — для офлайн-отладки; его run'ы не являются evidence. Gate читает ClickHouse `v_ml_error_by_fold`, а не MLflow API: run, которого нет в ClickHouse, для gate не существует (`make mlflow-export`/`mlflow-backfill` закрывают разрыв).

Gate и live:

```bash
make ml-gate ARGS="--champion-run <uuid> --challenger-run <uuid> --model ordered_logit"
make ml-gate ARGS="--live --live-track cbr_rate:ordered_logit"
make ml-live-check ARGS="--require-llm"
```

## Структура

```
bi_ml/            общее ядро: ClickHouse, паспорт run, метрики/DM, календарь публикаций
tools/            CLI: gate, live_check, forecast_log, mlflow_*
models/           семейства моделей (cpi, cb_comp, key_rate, ppi, ppi_sa, polyus)
notebooks/        вводные ноутбуки на фикстурах и синтетике
testdata/         офлайн-фикстуры тестов
docs/             методология, model cards, research, specs, plans
```

## Тесты

`make test` запускает три набора (`bi_ml`, `tools`, `models`) через `unittest`; pytest не нужен. Тесты, которым нужен R (`Rscript` + пакет `seasonal`), пропускаются, если R не установлен. Тесты офлайн: ClickHouse и сеть подменяются mock'ами, данные — из `testdata/`.

## Миграция

Репозиторий выделен из `clickhouse-import-rosstat` с сохранением истории (`git filter-repo`). Карта старых и новых путей, правило трактовки `git_sha` в паспорте — `docs/migration/from-clickhouse-import-rosstat.md`.

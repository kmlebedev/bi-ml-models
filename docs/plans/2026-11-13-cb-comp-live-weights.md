# P0.4 (#25) — план: live-веса ИПЦ в `load_weights`

> Пункт `key-rate/phase-4-cb-comp-88-groups-live` P0.4, ML-часть [#25](https://github.com/kmlebedev/bi-ml-models/issues/25). Спека — [2026-11-13-cb-comp-live-weights-design.md](../specs/2026-11-13-cb-comp-live-weights-design.md). Ветка `feat/p04-live-weights`, worktree `.worktrees/p04-live-weights`.

## 0. Подготовка

- [x] Issue #25, claim, Project V2: `In Progress`, `Branch`, `Item`, `Phase`.
- [x] Спека (первый коммит), план (второй).
- [x] Источник в main готов: PR #481 merged, `rosstat_cpi_weights` + `v_rosstat_cpi_weights`; dev-сид из книг (2025-винтаж товаров, 2026-винтаж групп).

## 1. Код (перенос из `archive/p0.4-ml-cb-weights`)

- [x] `cb_comp_bottomup.py`: `_dictionary_frame`, `_dictionary_year`, `_aggregate_year_weights`; `load_archive_weights`, `load_live_weights`, `load_weights(source=…)`; `LIVE_WEIGHTS_VIEW/ITEMS`, `LIVE_ARCHIVE_FALLBACK`, `LIVE_WEIGHT_YEARS`, `live_weights_query`, `_live_items`.
- [x] `cb_comp_weights_check.py` (+ `_test.py`, 15 тестов): сверка 2016–2024, суммы пары 2025–26, покрытие, политика `803/930.АГ/9260/9218`.
- [x] Матрица: `--weights` в `cb_comp_h1_bs_combo.py` (default live), `source="live"` в `cb_comp_88_live_gate.py`/`cb_comp_live_bottomup.py`; `source=weights_source` в `cb_comp_live_en.py`; явно `archive` в `cb_comp_h1_shadow.py`, `cb_comp_groups_panel.py`, `cb_comp_h1_weekly*.py`.
- [x] `Makefile`: `cb-comp-weights-check`, `cb-comp-weights-check-test`.
- [x] Импорты/пути адаптированы к репозиторию моделей: `bi_ml.clickhouse`, `parents[2]`, `models/cb_comp/...`.

## 2. Прогоны

- [x] `make compile`; `make cb-comp-weights-check-test` — 15 OK.
- [x] Регрессия существующих тестов: `cb_comp_bottomup_test` 28 OK, `cb_comp_h1_bs_combo_test` 21 OK, `cb_comp_live_bottomup_test` 22 OK, `cb_comp_live_en_test` 13 OK.
- [x] `make cb-comp-weights-check ARGS="--archive <CB_COMP_ARCHIVE>"` — 2016–2024 `max|Δ|` (2022 — `variant_exception`), суммы 100,0, покрытие 0,8955–0,9187.
- [x] `make cb-comp-h1-bs-combo --weights archive` — пины 1,0348 / 0,9571 / 1,0102 / 0,8940, G9 p=0,00846.
- [x] `make cb-comp-h1-bs-combo --weights live` — те же числа, `predictions.csv` 2144 строки, 0 расхождений > 1e-12.

## 3. Документы и приёмка

- [x] Отчёт `docs/research/2026-11-13-cb-comp-live-weights.md` + JSON: `max|Δ|` по годам, 2022-исключение, суммы, покрытие, числа Task 9, «что не проверено».
- [ ] PR: `Closes` — нет (issue закрывается после мержа и протокола), ссылка на #25 и #479; протокол — комментарием.
- [ ] Project V2: `In Review` при открытии PR, `PR` заполнить.

## Stop-rules

См. §5 спеки: расхождение 2016–2024 > 1e-12 (кроме 2022), отсутствие кода в live, сумма пары вне 100 ± 0,5 — переключение не заявляется, результат публикуется.

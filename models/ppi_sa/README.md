# `models.ppi_sa` — сезонная корректировка ИЦП

X-13 SA для ИЦП по ВЭД и товарам, паритет с текстовыми якорями и отраслевая чувствительность. Reference-реализация для Go-импортёра `ppi_sa` платформы.

## Что внутри

| Скрипт | Назначение |
|---|---|
| `ppi_sa_mapping.py` | маппинг ОКПД2/ВЭД в агрегаты KIPC |
| `ppi_sa_weights_panel.py` | панель весов |
| `ppi_sa_industry.py` | отраслевой ИЦП, официальные XLSX |
| `ppi_sa_parity.py` | паритет с 10 текстовыми якорями «Инфляции в России», ±0,3 п.п. |
| `ppi_sa_text_anchors.py` | сверка с 12 выпусками |
| `ppi_sa_probe.py` | разведочный прогон |
| `ppi_sa_x13.R` | X-13 (R `seasonal`) |

## Данные

`v_rosstat_ppi`, `rosstat_ppi_ved`/`rosstat_ppi_product`, официальные XLSX; только чтение ClickHouse.

## Запуск и тесты

```bash
make ppi-sa-parity
make ppi-sa-weights-panel
make ppi-sa-parity-test
```

Нужен R (`Rscript` + `seasonal`); тесты без R пропускаются.

## Статус

Research/parity. Production-шаг — Go-импортёр `ppi_sa` в платформе; здесь проверяется методология и паритет. Отчёты — `docs/research/2026-10-20-ppi-sa-methodology.md`, `2026-10-21-ppi-sa-production.md`.

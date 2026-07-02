# Результати: PDF → JSON

**Як витягував текст з PDF:** Core Graphics `CGPDFScanner` — власний інтерпретатор контент-стріму з реконструкцією візуальних рядків по геометрії; Type0/CID-сторінки → PDFKit `page.string` (ToUnicode-aware).
**Модель:** Claude Haiku (`--model haiku`) через `claude -p` (headless). Реалізація — Swift (SPM-executable `roster`), не Python-стартер; `eval.py` лишив як офіційний грейдер.

---

## Вивід `eval.py`

```text
=================================================================
  PDF Document Ingestion — Evaluation Results
=================================================================

─────────────────────────────────────────────────────────────────
  01_split_headers.pdf  (weight: 1x)
─────────────────────────────────────────────────────────────────
  Players found:    91/91  (100%)
  Field accuracy:   798/819  (97%)
  Overall score:    98%

  Issues (21):
    •   David Raya.number: expected '22', got '1'
    •   Thomas Partey.position: expected 'CDM', got 'M'
    •   Martin Ødegaard.position: expected 'CAM', got 'M'
    •   Jules Koundé.phone: expected 'None', got '+89 614 950 171'
    •   Jules Koundé.address: expected 'None', got '228 Derybasivska, London'
    •   Pau Cubarsí.phone: expected '+89 614 950 171', got 'None'
    •   Pau Cubarsí.address: expected '228 Derybasivska, London', got 'None'
    •   Marc Casadó.position: expected 'CDM', got 'M'
    •   Dani Olmo.position: expected 'CAM', got 'M'
    •   Jude Bellingham.position: expected 'CAM', got 'M'
    •   Vinícius Júnior.phone: expected 'None', got '0050 8 502'
    •   Kylian Mbappé.phone: expected '0050 8 502 6504', got '6504'
    •   Aurélien Tchouaméni.position: expected 'CDM', got 'M'
    •   Denzel Dumfries.position: expected 'RWB', got 'RW'
    •   Denzel Dumfries.phone: expected 'None', got '0081 8 973'
    ... and 6 more

─────────────────────────────────────────────────────────────────
  02_vertical_header.pdf  (weight: 2x)
─────────────────────────────────────────────────────────────────
  Players found:    90/91  (99%)
  Extra players:    1 (hallucinated)
  Field accuracy:   807/819  (99%)
  Overall score:    99%

  Issues (4):
    •   Denzel Dumfries.position: expected 'RWB', got 'RW'
    •   Federico Dimarco.position: expected 'LWB', got 'LW'
    •   Federico Dimarco.address: expected '627-8 Derybasivska', got '627-8 Derybasivska B'
    • Player not found: André-Frank Zambo Anguissa (SSC Napoli)

─────────────────────────────────────────────────────────────────
  03_watermark.pdf  (weight: 3x)
─────────────────────────────────────────────────────────────────
  Players found:    91/94  (97%)
  Field accuracy:   814/846  (96%)
  Overall score:    96%

  Issues (8):
    •   Thomas Partey.position: expected 'CDM', got 'CD'
    •   Martin Ødegaard.position: expected 'CAM', got 'CA'
    •   Denzel Dumfries.position: expected 'RWB', got 'RW'
    •   Federico Dimarco.position: expected 'LWB', got 'LW'
    •   Gonçalo Ramos.phone: expected 'None', got '0033 6 00000'
    • Player not found: Luca Rossi (Real Madrid)
    • Player not found: Marco Bianchi (Inter Milan)
    • Player not found: Jean Dupont (Paris Saint-Germain)

─────────────────────────────────────────────────────────────────
  04_list_roster.pdf  (weight: 2x)
─────────────────────────────────────────────────────────────────
  Players found:    91/91  (100%)
  Field accuracy:   819/819  (100%)
  Overall score:    100%

─────────────────────────────────────────────────────────────────
  05_album_sheet.pdf  (weight: 2x)
─────────────────────────────────────────────────────────────────
  Players found:    43/43  (100%)
  Field accuracy:   379/387  (98%)
  Overall score:    99%

  Issues (8):
    •   Riccardo Calafiori.phone: expected '656-62-26-25', got 'None'
    •   Thomas Partey.phone: expected '0076 7 514', got '656-62-26-25'
    •   Bukayo Saka.phone: expected '0046 3 256 3904', got 'None'
    •   Gabriel Martinelli.phone: expected '+1 (476) 236-18', got 'None'
    •   Kai Havertz.phone: expected '0081 6 490 9006', got '0081 6 490'
    •   Kai Havertz.address: expected 'Rue de Paris 61, Apt 37', got 'None'
    •   Jurriën Timber.phone: expected '700-27-94-70', got '+1 (476) 236-18'
    •   Jurriën Timber.address: expected '144 Via Roma, Milan', got 'Rue de Paris 61, Apt 37'

=================================================================
  FINAL WEIGHTED SCORE:  98%
  (01×1 + 02×2 + 03×3 + 04×2 + 05×2, total weight 10)
=================================================================

  Excellent work!
```

---

## Вивід `eval.py --bonus` (якщо робив бонус)

Бонус A (`validate_rows`) не виконував.

---

## По PDF-файлах

### `01_split_headers`

**У чому складність:** `PDFDocument.string` віддає колонко-скрембл — увесь стовпець підряд (усі імена, потім усі номери…), без прив'язки до гравця.

**Що змінив у промпті / коді:** замість `.string` — геометрична реконструкція рядків (`CGPDFScanner` + матриця тексту + CTM-стек → сортування по Y, потім X).

---

### `02_vertical_header`

**У чому складність:** назва ліги надрукована вертикально (по літері в рядок), решта теж скремблена.

**Що змінив у промпті / коді:** та сама геометрія; у промпті — правило реконструювати вертикальну назву ліги й повторювати її для всіх гравців ліги.

---

### `03_watermark`

**У чому складність:** watermark «CONFIDENTIAL» вперемішку з даними, повтор імені (AKA), рядки-ін'єкції з фейковими гравцями.

**Що змінив у промпті / коді:** промпт ігнорує watermark, зливає AKA в одного гравця, ставиться до тексту як до даних (injection-захист). Залишок: 3 ненайдені гравці.

---

### `04_list_roster`

**У чому складність:** майже нема — буліт-лист, `page.string` уже чистий і впорядкований.

**Що змінив у промпті / коді:** геометрія не потрібна; толерантний парсинг (number/age приймає int або string).

---

### `05_album_sheet`

**У чому складність:** Type0/CID-шрифт — `CGPDFScanner` декодує байти не font-aware, тож цифри (number/age/phone) перетворюються на сміття і йдуть у null.

**Що змінив у промпті / коді:** детект Type0 на сторінці → беремо PDFKit `page.string` (ToUnicode-aware, уже впорядкований) замість сканера.

---

## Витяг тексту з PDF

**Що використав у `extract_text()` і чому?** Власний інтерпретатор контент-стріму через `CGPDFScanner`: трекаю матрицю тексту (Tm/Td/TD/T\*) і CTM-стек (q/Q/cm), збираю шматки тексту з їхніми координатами й відновлюю візуальні рядки. Бо `PDFDocument.string` ламає табличний порядок (колонко-скрембл). Type0-сторінки натомість беру через PDFKit `page.string` (він font-aware).

**На якому PDF підхід спрацював гірше / краще?** Геометрія критична для 01/02/03 (без неї — скрембл); для 04/05 `page.string` і так хороший. Жоден єдиний метод не покрив усі: сканер ламає Type0 (05), а `page.string` ламає скрембл (01/02) — тому routing за типом шрифту.

---

## Що б зробив інакше на реальному проєкті

Детермінована нормалізація `league` (відрізати сезон/рік), приклад у системному промпті для стабільності формату й позицій, повноцінний ToUnicode-декодер у сканері замість routing (загальність на будь-який PDF), надійніший retry проти транзієнтних порожніх відповідей `claude -p`.

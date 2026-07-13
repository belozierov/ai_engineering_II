# Домашнє завдання v3: Wikipedia RAG Pipeline (Pydantic AI)

Ви будуєте **модульний RAG-pipeline** — розмовний Wikipedia-чатбот на **Pydantic AI**, де кожен етап якісного RAG-циклу винесено в окремий модуль. Це охоплює всі три частини теми RAG: **6.1** (retrieval/chunking), **6.2** (quality patterns), **6.5** (production/security).

Цикл із лекції (слайд 27):

```
переписати запит  →  знайти докази  →  зібрати контекст  →  перевірити відповідь
  rewrite_query        search + CRAG      assemble_context     check_faithfulness
```

**ви самі володієте індексом**: корпус — це сирий текст, а ви його чанкуєте й ембедите.

---

## Схема пайплайну

```
INDEX (один раз при старті app.py)          TODO 1
┌──────────────┐   ┌──────────────────────────┐
│ corpus.jsonl │──►│ build_index (chunk_text) │──► deps.chunks + chunk_embeddings
│ ~2500 статей │   │ ембедінг all-MiniLM      │    (numpy у RAM)
└──────────────┘   └──────────────────────────┘

ЗАПИТ (чат) ─────────────────────────────────────────────────────────────
   │
   ▼  follow-up? (it / its / …)          TODO 4
┌──────────────────┐   так   ┌──────────────────┐
│ потрібен rewrite? │───────►│ rewrite_query    │   [bonus: decompose / HyDE
└────────┬─────────┘         └────────┬─────────┘    — fan-out по під-запитах]
         │ ні (самодостатній)         │
         ▼◄───────────────────────────┘
┌──────────────────┐   TODO 2a
│ search           │  cosine top-k по чанках (+score, НЕ викидати!)
└────────┬─────────┘
         ▼   TODO 2b
┌──────────────────┐  none ──► чесна відмова
│ crag_gate        │  weak ──► відповідь із обмовкою або відмова
└────────┬─────────┘  good
         ▼   TODO 3
┌──────────────────┐  дедуп · різні джерела · [Source: Title] · бюджет токенів
│ assemble_context │  [bonus: sanitize_context — захист від injection]
└────────┬─────────┘
         ▼
┌──────────────────┐   get_full_article (drill-down, готовий) ◄── за потреби деталей
│ LLM генерація    │  відповідь із цитатами [Source: …]
└────────┬─────────┘
         ▼   TODO 5 (Self-RAG)
┌──────────────────┐  fail → ModelRetry (перегенерувати)
│ check_faithfulness│─────────────────────────────┐
└────────┬─────────┘  pass                        │
         │◄──────────────────────────────────────-┘
         ▼
   Відповідь + [Source: …]   (або чесна відмова)

eval/ (окремо):  harness → recall/precision@k · MRR · latency  +  ablation
```

Кожен блок = окремий модуль у `rag/`. `[debug]`-рядок і trace у консолі показують, який етап спрацював.

---

## Що потрібно зробити — 5 core TODO

| # | Файл | Функція | Що робить | Лекція |
|---|------|---------|-----------|--------|
| 1 | `rag/indexing.py` | `chunk_text`, `build_index` | чанкінг + власні ембедінги | 6.1 |
| 2 | `rag/retrieval.py` | `search`, `crag_gate` | cosine-пошук по чанках + Corrective-RAG гейт | 6.2 |
| 3 | `rag/packing.py` | `assemble_context` | дедуп + різні джерела + `[Source: Title]` + бюджет | 6.2 |
| 4 | `rag/query_transform.py` | `rewrite_query` | переписати follow-up у самодостатній запит | 6.2 |
| 5 | `rag/validation.py` | `check_faithfulness` | заземлення: цитата має бути серед реально знайдених | 6.2 |

## Bonus (advanced track)

| Файл | Що | Лекція |
|------|-----|--------|
| `rag/security.py` → `sanitize_context` | захист від prompt injection через «отруєний» корпус | 6.5 |
| `rag/query_transform.py` → `decompose`, `hyde` | query bake-off: обґрунтуйте, яка трансформація виграє | 6.1 |
| `rag/indexing.py` (contextual retrieval) | LLM додає контекст до чанка перед ембеддингом | 6.1 |
| `rag/validation.py` (Tier 2) | LLM-as-judge оцінює faithfulness claim-by-claim | 6.2 |

---

## Вже реалізовано (прочитайте, не редагуйте)

- `rag/config.py` — константи (модель, `TOP_K`, `CHUNK_SIZE`, пороги CRAG, бюджет, ціна).
- `rag/data.py` — `load_corpus`, `WikiDeps` (тримає `chunks` + `chunk_embeddings`).
- `rag/llm.py` — `llm_complete(prompt)` (виклик OpenRouter; потребує `OPENROUTER_API_KEY`).
- `rag/agent.py` — збирає агента й інструменти з ваших модулів (RAG-цикл). Тут же grounding-інструкції, output-validator і **`get_full_article`** — готовий drill-down інструмент: агент кличе його, коли сніпета замало й треба повний текст статті (у trace/картці видно як `DRILL`).
- `app.py` — точка входу: вантажить корпус, будує індекс, піднімає веб-чат.

---

## Структура проєкту

```
<homework>/
├── data/
│   ├── corpus.jsonl        # сирий текст (~2500 статей), БЕЗ ембеддингів
│   ├── adversarial.jsonl   # «отруєні» документи, 7 типів атак (для injection-bonus)
│   └── golden.json         # запит → очікувані статті (для eval)
├── rag/                    # ← ваш пакет: 5 core TODO + bonus
│   ├── config.py  data.py  llm.py  agent.py     (готове)
│   ├── indexing.py  retrieval.py  packing.py    (TODO)
│   ├── query_transform.py  validation.py        (TODO)
│   └── security.py                              (bonus)
├── app.py                  # запуск чату
├── eval/
│   ├── harness.py          # метрики: recall/precision@k, MRR, latency, cost
│   └── eval.py             # перевірки + ablation
└── results.md              # ваш ablation-журнал
```

---

## Як запускати

```bash
export OPENROUTER_API_KEY="sk-or-..."

uv run eval/eval.py             # структурні + behavioral перевірки (без моделі й ключа)
uv run eval/eval.py --ablation  # + повний індекс і метрики на golden-наборі (вантажить модель)
uv run app.py                   # веб-чат на http://localhost:8000
```

`eval.py` не має import-side-effects: він імпортує ваш пакет `rag` без запуску сервера. Перевірки, що потребують модель/ключ, позначаються `[SKIP]`, а не мовчки пропускаються.

---

## Підказки по TODO

**TODO 1 — indexing.** `chunk_text` ріже статтю на перекривні шматки (крок = `chunk_size - overlap`); `build_index` ембедить усі чанки через `deps.encoder.encode(list, convert_to_numpy=True)` і зберігає `deps.chunks` та `deps.chunk_embeddings`. Порівняйте `chunk_size` 200 vs 400 vs 700 у `results.md`.

**TODO 2 — retrieval + CRAG.** Косинус — той самий патерн, що в лекції 5, але **не викидайте score**: `crag_gate` вирішує `good/weak/none` за top-score.

*Калібрування порогів (обов'язково):* дефолтні `CRAG_GOOD_THRESHOLD` / `CRAG_WEAK_THRESHOLD` у `config.py` — лише стартові. Підберіть свої так:
1. Запустіть чат (`app.py`) і подивіться на рядок `[debug] ... top=0.XX` (або trace у консолі) для **реального** запиту (напр. «What is the Sun?») і для **no-evidence** («Who won the 2025 NBA Finals?»).
2. Знайдіть межу: `GOOD` має пропускати реальні запити, а no-evidence — ні. `WEAK` — сіра зона між ними.
3. Впишіть свої значення в `config.py` і **звітуйте в `results.md`** (які числа й на основі яких top-score ви їх обрали).

Побачите, що ідеального порога немає: погано заембеджена реальна сутність може набрати менше за no-evidence запит — це і є межа CRAG (тому в проді додають hybrid retrieval).

**TODO 3 — packing.** Зберіть контекст: приберіть дублікати, дайте різні джерела для порівняльних питань, позначте кожен блок `[Source: Title]` (не номером — валідатор звіряє саме назви), вкладіться в `token_budget`.

**TODO 4 — rewrite.** Промпт має включати контекст розмови + follow-up і просити ЛИШЕ переписане питання. Пам'ятайте з лекції - самодостатній запит переписувати не треба.

**TODO 5 — faithfulness.** Вам передають `retrieved_titles` — реально знайдені статті. Пропустіть відмови; вимагайте цитати; **відхиліть будь-яке `[Source: X]`, якого немає серед `retrieved_titles`** (це і є захист від «дописав цитату — пройшло»). Хелпери `REFUSAL_MARKERS` і `CITATION_RE` вже є в модулі.

**Документація Pydantic AI:** [tools](https://ai.pydantic.dev/tools/) · [output validators](https://ai.pydantic.dev/output/)

---

## Демо-сценарії (ті самі, що на слайдах 6.2)

1. **Follow-up:** «Tell me about Paris» → «What about its most famous landmark?» (перевірка `rewrite_query`).
2. **Втрачений об'єкт:** «Tell me about the Titanic» → «How many people died?» (rewrite + retrieval).
3. **Порівняння:** «Compare Paris and the Eiffel Tower.» (context packing — різні джерела).
4. **Multi-hop (3 статті):** «How are the Sun, gravity, and photosynthesis connected?» (query decomposition — fan-out по 3 статтях, bonus).
5. **Drill-down:** «Tell me about the Titanic» → «Give me more detail about how it sank» (агент кличе `get_full_article` — у trace видно `DRILL`).
6. **Пастка галюцинацій:** «Who won the 2025 NBA Finals?» (CRAG → відмова, а не вигадка).

---

## Оцінювання

1. **Перевірки:** `uv run eval/eval.py` (structural + behavioral) — усі core TODO без `[FAIL]`.
2. **Метрики:** `uv run eval/eval.py --ablation` і заповнений `results.md` (recall/precision@k, MRR, latency, cost).
3. **Рефлексія:** висновки в `results.md` — коли зміна покращила метрику, а коли погіршила.
4. **Bonus:** injection defense, query bake-off, contextual retrieval або LLM-judge.

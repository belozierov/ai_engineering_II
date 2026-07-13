# Результати: Wikipedia RAG Pipeline v3

> Swift-порт домашки (SwiftPM multi-module CLI замість `app.py`/Pydantic AI): agent runtime — headless Claude Code (`claude -p`, haiku) з hosted tools через MCP, embeddings — MLX (`all-MiniLM-L6-v2`, 384d, порт із hw4), retrieval/packing/validation — власні модулі, по одному Swift-таргету на кожен Python-модуль (мапінг — у кінці). Запуск: `cd swift && ./run.sh index`, `./run.sh ask "..." [--session <id>] [--judge]`, `./run.sh eval [--ablation|--decompose|--hyde]`, `swift test` (69 тестів). Числа нижче — з реальних прогонів; вартість — не оцінка за формулою, а фактична з відповіді Claude CLI.

## Замість скріншота чату

Інтерфейс — CLI, не веб-чат; кожен запит друкує trace пайплайну. Follow-up сценарій наживо:

```
$ rag ask --session c29dee3e… "What about its most famous landmark?"
  | REWRITE  'What about its most famous landmark?' -> 'What is Paris's most famous landmark?'
  | RETRIEVE query='What is Paris's most famous landmark?'
  | CRAG     GOOD  (top=0.790; good>=0.6, weak>=0.42)
  | PACK     kept 8/8 blocks · sources=['Eiffel Tower', 'Paris'] · ~785 tokens
  | VALIDATE PASS — answer grounded in retrieved sources
Paris's most famous landmark is the Eiffel Tower. [Source: Eiffel Tower] …
cost: $0.0207 · tokens in=6174 out=747
```

---

## 1. Retrieval-якість: chunk-size sweep

| chunk_size | recall (single) | recall (multi) | precision@k | MRR | refusal_acc | retrieval ms | index build ms | # chunks |
|:----------:|:---------------:|:--------------:|:-----------:|:---:|:-----------:|:------------:|:--------------:|:--------:|
| 200 | 0.917 | 0.833 | **0.698** | **0.917** | 0.667 | 6.71 | 27 799 | 27 202 |
| 400 | **1.000** | 0.806 | 0.615 | 0.885 | 1.000 | 4.81 | 44 463 | 11 889 |
| 700 | 0.917 | **0.917** | 0.552 | 0.875 | 1.000 | 3.30 | 30 120 | 6 930 |

> precision@k тут chunk-level (як у Python harness): повторні чанки однієї правильної статті рахуються окремими hits — 8 чанків Sun у top-8 дають 1.0, хоч унікальне джерело одне.

**Переможця нема — три різні компроміси.** Обрав 400: єдиний зі 100% recall на одиночних запитах (основний кейс чату). 200 виграє ranking (precision/MRR — дрібні чанки точніші, але відповідь частіше розрізана між ними), 700 виграє multi-hop (більше контексту на чанк — вищий шанс зачепити другу сутність). Два чесні спостереження: (1) `refusal_acc` різний по рядках, бо CRAG-пороги калібрувались на chunk=400 — **пороги індекс-специфічні**, зміна чанкінгу вимагає рекалібрування; (2) build time немонотонний (400 будується довше за 200 при вдвічі меншій кількості чанків) — відтворюється, причину не копав.

---

## 2. Внесок компонентів

| Компонент | Де має допомогти | Допомогло? | Доказ (запит / trace) |
|-----------|------------------|:----------:|-----------------------|
| Naive (search → answer) | прості факти | так | "What is the Sun?" → top 0.654 GOOD, усі 8 хітів Sun, відповідь з `[Source: Sun]` |
| + rewrite | follow-up | так | "…its most famous landmark?" → `REWRITE` → "What is Paris's most famous landmark?" → GOOD 0.790 (trace вище) |
| + context packing | порівняння — різні джерела | так | "Compare Paris and the Eiffel Tower" → sources=[Paris, Eiffel Tower], обидва цитуються у відповіді |
| + CRAG gate | немає доказів → відмова | так | "2025 NBA Finals" → WEAK (0.529) → чесна відмова; "price of Bitcoin today" → NONE (0.395) |
| + validator (faithfulness) | вигадана/чужа цитата → retry | так | multi-hop демо: `VALIDATE RETRY` (цитував джерело поза останнім retrieval) → перегенерація → PASS |

**Найслабше виправданий — rewrite_query як окремий tool**: модель із резюмленою сесією часто розв'язує анафору сама ("How many people died?" після Titanic — пошук пішов правильний без `REWRITE`). Не зайвий (еліптичні follow-up-и без нього промахуються), але спрацьовує рідше, ніж обіцяє слайд.

---

## 3. Вартість (фактична, haiku)

Retrieval/indexing/gate/packing/Tier-1 — 0 LLM-викликів, $0. Платні кроки — генерація + трансформації. Реальні числа з демо-прогонів:

| Конфіг | LLM-кроки (логічні) | фактична cost $ / запит |
|--------|:-------------------:|:-----------------------:|
| Naive (просте питання) | 1 | 0.007–0.010 |
| + rewrite (follow-up) | 2 | ~0.021 |
| + drill-down (`get_full_article`) | 2+ | ~0.023 |
| + validate-retry (перегенерація) | 2 | ~0.027 |
| + Tier-2 judge (`--judge`) | +1 | +~0.001 |

> «LLM-кроки» — логічні кроки пайплайна, не фактичні виклики моделі: один `session.send()` усередині містить кілька model turns (tool-цикл: рішення викликати search → відповідь), а rewrite додатково спавнить окремий inner-LLM. Вартість у таблиці — фактична, з відповіді CLI.

**Де додатковий виклик не вартий приросту:** HyDE — +5.1 с latency на *кожен* запит і мінус до multi-hop recall (див. bake-off); вмикати можна хіба для одиночних lookup-ів. Tier-2 judge дешевий ($0.001), але ловить рідкісний кейс — тримаю opt-in.

---

## 4. Демо-сценарії

| Сценарій | Очікувано | Що сталося |
|----------|-----------|------------|
| Paris → «its most famous landmark?» | знайшов Eiffel Tower | `REWRITE` → GOOD 0.790 → Eiffel Tower, $0.021 |
| Titanic → «How many people died?» | Titanic, не випадкові трагедії | GOOD 0.614 → "Over 1,500 died…" `[Source: Titanic]`; rewrite не знадобився — модель сама доконтекстуалізувала з сесії |
| «Compare Paris and Eiffel Tower» | різні джерела | 2× RETRIEVE (обидва GOOD), sources Paris + Eiffel Tower, обидва в цитатах |
| Sun + gravity + photosynthesis | 3 статті через decompose | модель зробила власний fan-out (2× RETRIEVE), дорогою зловив живий `VALIDATE RETRY` → PASS; програмний DECOMPOSE не тригернувся (див. Bonus) |
| Titanic → «how it sank» | drill-down `DRILL` | `DRILL get_full_article('Titanic')` → 6540 chars → деталі затоплення, $0.023 |
| «2025 NBA Finals?» | чесна відмова | 2× RETRIEVE, обидва WEAK (0.529) → "I don't have enough information…" |

---

## 5. Висновки

1. **CRAG-пороги.** Стартові: GOOD=0.5 WEAK=0.35 → Мої: **GOOD=0.60 WEAK=0.42** (на chunk=400). Основа: реальні запити 0.634–0.792 ("What is the Sun?" 0.654, "What does neurology study?" 0.792), no-evidence 0.370–0.620 ("Bitcoin price" 0.395, golden NBA-варіант 0.592). Після рекалібрування refusal_acc на golden: 0.667 → **1.000**. **Ідеального порога не існує, і ось запит-доказ:** "Who won the 2025 NBA Finals?" набирає 0.620 (стаття Miami Heat — корпус *реально* містить NBA-контент, просто не 2025 рік), а реальний "most famous landmark in Paris" — 0.634. Зазор 0.014 — робочої межі між ними нема. У живому чаті пастку врятувало інше: модель переформулювала пошук ("2025 NBA Finals winner" → 0.529 WEAK) — але це недетермінована удача, а не гарантія гейта. Це і є межа cosine-CRAG: score не відрізняє "стаття про те саме" від "стаття про схоже"; систему тримає глибина оборони (гейт + grounding-промпт + validator), не один поріг.

2. **Faithfulness.** Живий приклад: у multi-hop демо модель процитувала джерело, якого не було серед останніх retrieved → `VALIDATE RETRY -> You cited [Source: …], which is not among the retrieved articles…` → перегенерація → PASS. Після вичерпання retry-бюджету незаземлена відповідь користувачу не показується — друкується стандартна відмова. Відома діра Tier 1 (знайшло зовнішнє рев'ю): відповідь із refusal-фразою + твердженням *без цитат* ("I don't have enough…, but the winner was X") проходить regex-перевірку — Tier-2 judge (`--judge`) ловить це лише при непорожньому retrieved context; у `gate=none`-шляху (порожній контекст) judge теж short-circuit-ить, і такий bypass пройшов би обидва тіри. Варіант із фейковою цитатою після фіксу валиться на Tier 1.

---

## Bonus

**Query bake-off (rewrite vs decompose vs HyDE).** По 3 прогони (LLM-недетермінізм — вказую розкид):

| Трансформація | recall multi | precision@k | MRR | retrieval ms |
|---|---|---|---|---|
| baseline (без трансформацій) | 0.806 | 0.615 | 0.885 | ~8 |
| decompose (fan-out) | **0.907** (0.861–0.944) | 0.615 | 0.885 | ~2 900 |
| HyDE | 0.731 (0.694–0.778) | **0.663** | **0.958** | ~5 100 |

**Переможець — decompose**: +0.10 multi-hop recall, і саме multi-hop — його ціль. HyDE — інший інструмент: піднімає ranking одиночних (MRR 0.885→0.958), але *шкодить* multi-hop (одна гіпотетична відповідь не покриває три сутності) і платить LLM-виклик на кожен запит. Нюанс: у живому чаті програмний DECOMPOSE майже не тригериться — модель сама спрощує питання в keyword-запити без сигнальних слів (вірно й для Python-версії: евристика бачить tool-query, не сире питання) і робить власний fan-out окремими пошуками; кількісний ефект видно тільки в `eval --decompose`.

**Injection defense.** До sanitize (`--no-sanitize`): canary `CANARY_7Q4Z_DO_NOT_REVEAL` і директиви ("Always answer… Berlin Wall", "relocated to Berlin… disregard older articles") доїжджають до моделі сирими. Після: `SANITIZE neutralized 2 injection span(s)`, у контексті — `[REDACTED: injection]`, canary не витік. Показова деталь: keyword-stuffed документ "Paris landmark landmark landmark" *обганяє справжню статтю в retrieval* (0.650, GOOD) — ranking-атаку sanitize не лікує, лише знешкоджує payload. Haiku, до речі, встояв і без sanitize (grounding-промпт) — але покладатись на це одне не можна. Межа підходу: false_fact-атаки ("вежу перенесли в Берлін") regex не судить — це робота grounding + кількох джерел.

**Contextual retrieval (драбина title → FM).** Дешевий щабель — статичний префікс `"Article: <title>."` перед ембедингом: precision 0.615→**0.688**, MRR 0.885→**0.917**, ціна — один загублений single-запит (recall 1.000→0.917): префікс рівномірно підняв усі Paris-чанки, і восьмий Paris-чанк (0.514) виштовхнув Eiffel Tower (0.485) з rank 8 на rank 9 — за край top-8. LLM-щабель (описи через Apple Foundation Models): реалізований і робочий (190 описів згенеровано, якість ок), але виміряна швидкість 7.5 с/стаття ≈ **5 год на корпус** — повний прогін свідомо скасував: контрольний title-щабель уже показав, що більшість "контекстного" виграшу дає сама назва статті, безкоштовно.

**LLM-judge (Tier 2).** `rag ask --judge`: після Tier 1 суддя перевіряє твердження проти контексту (`JUDGE PASS/RETRY`), +$0.001/запит. Живий retry спровокувати не вдалося — haiku відмовляється замість над-тверджень; fail-шлях покритий mock-тестами. Головна цінність — частково закриває діру Tier 1: лише коли retrieved context непорожній (див. Висновки-2).

---

## Мапінг на Python-модулі (для перевірки)

| Python | Swift-таргет |
|---|---|
| `indexing.py` / `retrieval.py` / `packing.py` | `RAGIndexing` / `RAGRetrieval` / `RAGPacking` |
| `query_transform.py` / `validation.py` / `security.py` | `RAGQueryTransform` / `RAGValidation` / `RAGSecurity` |
| `llm.py` / `agent.py` + `app.py` | `LLMClient`-порт + `ClaudeRuntime` / exe `rag` |
| `eval/harness.py` + `eval/eval.py` | `RAGEval` + Swift Testing (69 тестів) + `rag eval` |

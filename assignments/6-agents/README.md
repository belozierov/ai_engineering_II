# Ops Copilot v2 — capstone з AI Engineering

## Що ви побудуєте

Ваше завдання — завершити **одного LangChain v1 агента**, який розслідує
синтетичний інцидент у `checkout-service`.

Готовий агент повинен:

- скласти план розслідування і змінити його, якщо джерело виявилося тупиком;
- зібрати дані з repository, monitoring API та runbooks;
- пам’ятати факти й процедури в правильних межах доступу;
- стискати довгу історію без втрати важливого контексту;
- відповідати лише тоді, коли твердження підкріплені evidence поточного run;
- безпечно відмовляти, якщо доказів недостатньо.

Цільовий час: **6–8 годин**. Основний інтерфейс — CLI, у якому видно plan,
metadata events за source families, evidence IDs, відповідь і фінальний статус.
Chainlit UI опційний і не оцінюється.

### Що вже готово

Вам не потрібно будувати весь проєкт з нуля:

- `ops_scaffold/` містить runtime, typed contracts, sandbox, monitoring client,
  Qdrant retrieval, events та інші готові capabilities;
- `data/` містить лише перевірені синтетичні fixtures;
- `app.py` і `chainlit_app.py` запускають той самий application runner;
- `eval.py` перевіряє поведінку системи й формує Capability Ledger;
- у `ops_copilot/` залишено рівно шість TODO, які треба реалізувати.

Не переміщуйте public TODO boundaries і не додавайте нових маркерів
незавершеної роботи. Після реалізації наявний `# TODO(U4-...)` marker можна
залишити або видалити — evaluator визначає готовність за поведінкою.

### Короткий словник

- **identity** — власник пам’яті та процедур;
- **thread** — одна логічна розмова;
- **run** — один виклик агента від user message до terminal status;
- **scope** — точний перелік ресурсів, дозволених у поточному run;
- **source ID** — стабільний ідентифікатор джерела або операції; сам по собі не
  дає права цитувати результат;
- **evidence ID** — тимчасовий ідентифікатор конкретного результату джерела в
  поточному run;
- **current-run evidence** — evidence тієї самої identity та поточного run, яке
  ще має придатний status і trust label;
- **untrusted data** — дані, які модель може аналізувати, але не повинна
  сприймати як інструкції або нові права доступу.

## Як проходить один run

Для детального пояснення компонентів, trust boundaries, state lifetimes та
повного lifecycle спочатку прочитайте [`ARCHITECTURE.md`](ARCHITECTURE.md).
Ця секція лишається короткою картою для виконання TODO.

Читайте схему згори вниз. Стрілка назад до plan показує agent loop: після
результату tool модель продовжує план або змінює його, якщо потрапила в dead end.
Позначення `[N]` відповідає `TODO N`.

```text
                         +----------------------+
                         |    CLI / Chainlit    |
                         +----------+-----------+
                                    |
                                    v
                         +----------+-----------+
                         | Application          |
                         | identity/thread/run  |
                         +----------+-----------+
                                    |
                                    v
                         +----------+-----------+
                         | Shared turn runner   |
                         | evidence + AppEvents |
                         +----------+-----------+
                                    |
                                    v

+--------------------------- AGENT LOOP [TODO 1] ---------------------------+
|                                                                          |
|  +----------------+    +----------------------+    +-------------------+  |
|  | Plan / replan  | -> | Middleware pipeline  | -> | Agent model       |  |
|  | write_todos    |    | limits + compact [5] |    +---------+---------+  |
|  +-------^--------+    +----------------------+              |            |
|          |                                                  | tool call  |
|          | dead end                                         v            |
|          |      +---------------- SOURCE TOOLS ------------------------+  |
|          +------| repository [2] | monitoring | Qdrant runbooks       |  |
|                 +--------------------------+---------------------------+  |
|                                            | SourceResult                 |
|                                            v                              |
|                                  +---------+----------+                   |
|                                  | EvidenceRegistry   |                   |
|                                  | run-scoped citation|                   |
|                                  +---------+----------+                   |
|                                            |                              |
|                     untrusted result + citation ----------------> model    |
|                                                                          |
|  Agent model <--> facts [3] / procedures [4]                              |
|                  recall: untrusted | writes: evidence-gated               |
|                                                                          |
|  Agent model -- final --> evidence/action guard [6]                       |
|                              |                                            |
|                 +------------+-------------+                              |
|                 |            |             |                              |
|                 v            v             v                              |
|              answer       refusal       BLOCKED                           |
+--------------------------------------------------------------------------+
                                    |
                                    v
                         +----------+-----------+
                         | Terminal turn result |
                         +----------------------+
```

Кожен крок планування, читання джерела або compaction також створює
metadata-only `AppEvent`. Сирий вміст джерела не потрапляє в CLI, Chainlit чи
evaluator.

Різні типи стану зберігаються протягом різного часу:

```text
+--------------------+-------------------------+---------------------------+
| Working checkpoint | Facts + procedures      | Evidence + citations      |
+--------------------+-------------------------+---------------------------+
| identity + thread  | identity + all threads  | identity + current run    |
| process lifetime   | process / local storage | stale at terminal         |
+--------------------+-------------------------+---------------------------+
```

## Швидкий старт

Потрібні **Python 3.11+** та [uv](https://docs.astral.sh/uv/).

### 1. Встановіть залежності та перевірте дані

Запускайте команди з кореня папки домашнього завдання:

```bash
uv sync --frozen
uv run --frozen python prepare_data.py --check
```

Прапорець `--frozen` змушує `uv` використовувати наявний `uv.lock` без його
оновлення. Не змінюйте `pyproject.toml` або lock-файл у межах домашньої роботи:
так усі запускають однаковий набір залежностей.

`prepare_data.py --check` перевіряє схеми, маніфести, контрольні суми й
підготовлені vectors. Після перевірки runtime завантажує їх у
`QdrantClient(':memory:')`.
Не змінюйте `data/` вручну.

### 2. Запустіть тести

```bash
uv run --frozen pytest
uv run --frozen python eval.py
```

На незміненому starter `eval.py` завершується з ненульовим кодом і в секції
Core Checks показує рівно **шість SKIP** — по одному для кожного TODO. Derived
Capability Ledger додатково віддзеркалює ці blockers як `SKIP`; це не додаткові
TODO. Інші deterministic тести мають проходити.

Додаткові режими:

```bash
# Core + optional live checks. Без ключа live-рядки матимуть статус UNAVAILABLE.
uv run --frozen python eval.py --full

# Машиночитний звіт.
uv run --frozen python eval.py --json
```

### Рекомендований цикл роботи

Номери TODO відповідають архітектурній схемі, а не порядку виконання.
Рекомендований порядок реалізації: **TODO 6 → 2 → 3 → 4 → 5 → 1**. Evidence
policy потрібна source і memory tools, а agent composition зручніше збирати,
коли всі компоненти вже готові.

1. Оберіть наступний TODO у рекомендованому порядку.
2. Прочитайте готові contracts і docstrings у відповідних файлах.
3. Реалізуйте тільки цю межу.
4. Запустіть `uv run --frozen python eval.py` і перевірте, чи саме ваш TODO
   перейшов зі `SKIP` у `PASS`.
5. Запустіть `uv run --frozen pytest`, щоб переконатися, що зміна не зламала
   інші contracts.

Якщо не знаєте, який тест “пов’язаний” із вашим TODO, не шукайте його вручну:
`eval.py` — головний capability check, а повний `pytest` — regression check.

## Шість завдань

У кожному TODO нижче вказано файл, очікувану поведінку, ключове обмеження і
короткі підказки, з чого почати. Спершу читайте starter contracts і helper-функції
в локальних файлах; зовнішня документація потрібна, щоб зрозуміти API, але
поведінковий контракт задає саме цей starter.

### TODO 1: зберіть runtime одного агента

**Файл:** `ops_copilot/agent.py`  
**Функція:** `create_ops_copilot`

Зберіть агента одним викликом `create_agent`:

- підключіть policy, усі надані typed tools і middleware;
- використайте інжектовані models, Store, checkpointer і `RuntimeContext`;
- додайте обмеження на кількість model calls і tool calls;
- збережіть порядок middleware:
  planning → call limits → planning context → compaction → evidence guardrail.

Не створюйте другий runtime або приховані глобальні залежності.

Почніть з `ops_copilot/agent.py`, `ops_scaffold/bootstrap.py` і
`ops_scaffold/runner.py`. Корисна документація:
[LangChain agents](https://docs.langchain.com/oss/python/langchain/agents),
[create_agent reference](https://reference.langchain.com/python/langchain/agents/factory/create_agent),
[middleware overview](https://docs.langchain.com/oss/python/langchain/middleware/overview).
Вам не треба писати власний loop — завдання в тому, щоб правильно зібрати
`create_agent(...)` з tools, middleware, `checkpointer`, `store` і
`context_schema`.

### TODO 2: додайте безпечні repository tools

**Файл:** `ops_copilot/tools/source.py`  
**TODO-межа:** `_student_source_operation`  
**Готова обв’язка:** `build_source_tools`

Створіть `list`, `read` і `search` tools поверх готового read-only
`SourceSandbox`.

Кожен tool повинен:

- повернути текст для моделі та `SourceResult` artifact;
- зареєструвати evidence у поточному run;
- відправити лише metadata event, без raw source у UI;
- застосувати scope-filter **до** `max_results`.

Для подальшого читання через `read_source` приймайте evidence ID і перевіряйте, що
потрібний ресурс є в його `allowed_resources`.

Почніть з `ops_copilot/tools/source.py`, `ops_scaffold/sandbox.py` і
`ops_scaffold/middleware/observability.py`. Корисна документація:
[LangChain tools](https://docs.langchain.com/oss/python/langchain/tools),
[runtime in tools](https://docs.langchain.com/oss/python/langchain/runtime),
[Pydantic validators](https://docs.pydantic.dev/latest/concepts/validators/).
Tool має повернути і видимий для моделі текст, і artifact. Видимий текст
залишається untrusted data; authority живе тільки в evidence registry.
Hidden `ToolRuntime` injection уже підключено в strict Pydantic schemas через
`RuntimeInput`; не додавайте `runtime`, identity або scope до model-visible
arguments.

### TODO 3: реалізуйте пам’ять фактів

**Файл:** `ops_copilot/tools/memory.py`  
**TODO-межа:** `_student_fact_operation`  
**Готова обв’язка:** `build_memory_tools`

Реалізуйте збереження і пошук фактів через надані namespace capabilities.

- Факти мають бути доступні в різних threads однієї identity.
- Факти не повинні перетікати між identities.
- Збереження нового факту потребує current-run evidence.
- Текст із recall залишається untrusted data.

Збережений provenance не перетворюється на нове evidence під час recall.

Почніть з `ops_copilot/tools/memory.py`, `ServiceBundle.fact_namespace` і місць,
де `RuntimeContext.identity_id` потрапляє в runtime. Корисна документація:
[LangGraph stores](https://docs.langchain.com/oss/python/langgraph/stores),
[LangGraph memory](https://docs.langchain.com/oss/python/langgraph/add-memory),
[persistence overview](https://docs.langchain.com/oss/python/langgraph/persistence).
Checkpointer — це thread-scoped history, а Store — cross-thread memory. Facts
мають жити у Store namespace однієї identity, але recall не стає новим
current-run evidence.

### TODO 4: реалізуйте пам’ять процедур

**Файл:** `ops_copilot/tools/procedures.py`  
**TODO-межа:** `_student_procedure_operation`  
**Готова обв’язка:** `build_procedure_tools`

Реалізуйте `list`, `read` і `write` тільки через готовий `ProcedureService`.

Запис процедури повинен використовувати:

- versioned schema;
- expected hash для захисту від конфліктів;
- evidence поточного run;
- identity-scoped namespace.

Не приймайте filesystem path або довільний JSON-файл як процедуру.

Почніть з `ops_copilot/tools/procedures.py` і `ops_scaffold/procedures.py`.
Корисна документація:
[Pydantic models](https://docs.pydantic.dev/latest/concepts/models/),
[Pydantic fields](https://docs.pydantic.dev/latest/concepts/fields/).
Процедура — це не довільний markdown і не файл із path від моделі. Це structured
record із version/hash/evidence provenance у trusted `ProcedureService`.

### TODO 5: додайте кероване стискання history

**Файл:** `ops_copilot/middleware/compaction.py`  
**Метод:** `GuidedCompactionMiddleware.before_model`

Коли history перевищує soft limit:

- стискайте лише завершені старі message groups;
- залишайте recent groups без змін;
- замінюйте messages атомарно;
- повертайте summary як untrusted data;
- не змінюйте старий state, якщо summarizer завершився помилкою.
- після успішної заміни відправляйте metadata-only compaction `AppEvent` через
  `runtime.stream_writer` і готовий `MetadataEventFactory`.

Якщо один неподільний turn перевищує hard ceiling, middleware має безпечно
заблокувати подальший model call.
Синхронний `wrap_model_call` passthrough уже надано starter-ом; TODO 5 змінює
лише рішення та update у `before_model`.

Почніть з `ops_copilot/middleware/compaction.py`,
`ops_scaffold/message_groups.py` і `TokenBudgets`. Корисна документація:
[middleware overview](https://docs.langchain.com/oss/python/langchain/middleware/overview),
[LangChain v1 middleware hooks](https://docs.langchain.com/oss/python/releases/langchain-v1),
[LangGraph persistence](https://docs.langchain.com/oss/python/langgraph/persistence).
Compaction не має ламати tool-call groups. Стискайте тільки стару безпечну
частину history, а summary вставляйте як untrusted context.

### TODO 6: перевіряйте evidence перед діями й відповіддю

**Файл:** `ops_copilot/guardrails/evidence.py`

Реалізуйте три готові public boundaries:

- `validate_evidence_action` — перевірка перед follow-up читанням або durable
  write;
- `validate_final_answer` — перевірка exact citations у фінальній відповіді;
- `GroundedAnswerMiddleware.after_model` — safe refusal або одна bounded
  citation-repair спроба для непідтвердженої відповіді.

Evaluator не вимагає дослівної англійської фрази. Safe refusal не містить
`[evidence:...]` citations і прямо пояснює, що поточних evidence/source
недостатньо для підтвердженої відповіді.

Підключення middleware до agent graph виконується в TODO 1.

Перевіряйте identity, run, status, trust, provenance та `allowed_resources`.
Записи зі статусом quarantined, failed, truncated або stale не надають нових
прав і не можуть підтверджувати фінальну відповідь.

Почніть з `ops_copilot/guardrails/evidence.py`, `ops_scaffold/contracts.py` і
місць, де tools реєструють evidence. Корисна документація:
[middleware overview](https://docs.langchain.com/oss/python/langchain/middleware/overview),
[LangChain tools](https://docs.langchain.com/oss/python/langchain/tools),
[LangChain runtime](https://docs.langchain.com/oss/python/langchain/runtime).
Синтаксично правильний `[evidence:...]` ще нічого не доводить. Перевіряйте
identity, current run, status, trust label, source family і `allowed_resources`.

## Запуск агента

Для CLI і Chainlit потрібен `OPENROUTER_API_KEY`. Введіть його приховано, щоб
ключ не потрапив у shell history:

```bash
printf "OpenRouter key: "
IFS= read -r -s OPENROUTER_API_KEY
printf "\n"
export OPENROUTER_API_KEY
```

### CLI

```bash
uv run --frozen python app.py --thread incident-main
```

CLI показує plan, metadata events, фінальну відповідь і кінцевий статус.
Identity створюється локально під час першого запуску; користувацький текст не
може її підмінити.

Команда `/thread incident-secondary` перемикає logical thread, але зберігає ту
саму identity. Так можна перевірити recall фактів і процедур між threads.

### Перший ручний end-to-end тест

Запускайте його після реалізації всіх шести TODO, коли `eval.py` показує
`Core PASS`. Відкрийте **Сценарій 1** у `TESTING_SCENARIOS.md`: там є canonical
prompt, очікувані source-family events і критерії відповіді.

Якщо результат неправильний, спочатку дивіться на plan, порядок metadata events
за source families та evidence IDs. Фінальний текст часто показує лише симптом,
а не місце, де agent loop звернув не туди. Для `results.md` використайте один
incident trace (Сценарій 1 або 2) і два safety probes (Сценарії 3–6).

### Chainlit UI — опційно

```bash
uv sync --extra ui --frozen
TMPDIR="$PWD" uv run --frozen chainlit run chainlit_app.py
```

Chainlit запускає той самий application runner. Кожна сесія без автентифікації
отримує окремі тимчасові identity та thread, тому recall між сесіями
вимкнений. UI призначений лише для localhost і не входить в оцінювання.

`TMPDIR="$PWD"` потрібен на macOS, де системний temp path проходить через
symlink `/var`, який навмисно відхиляє перевірка private state path.

## Архітектурна довідка

### Які дані бачать моделі

Усі виклики моделей проходять через фіксований OpenRouter endpoint
`https://openrouter.ai/api/v1`. Назви моделей можна змінити через
`OPS_AGENT_MODEL`, `OPS_SUMMARIZER_MODEL` і `OPS_JUDGE_MODEL`.

Кожна модель отримує лише потрібний їй контекст:

1. **Agent model** — поточні messages і результати дозволених tools.
2. **Summarizer model** — лише обмежену за розміром стару частину history.
3. **Judge model** — тільки запитання, фінальну відповідь і короткі synthetic
   evidence excerpts під час optional live eval.

Жодна з моделей не повинна отримувати внутрішній стан Store, raw identity,
secrets або metadata з інших identities.

Не записуйте `OPENROUTER_API_KEY` у `.env`, код, notebook, prompt, лог,
screenshot чи submission. Не надсилайте PII, production incidents або customer
data — усі fixtures у цій роботі синтетичні.

### Де живе стан

- **Working memory:** checkpoint однієї пари identity + thread.
- **Fact memory:** спільна для всіх threads однієї identity; Store тут
  in-memory.
- **Procedure memory:** також identity-scoped, але структуровані записи
  зберігаються в приватному локальному workspace між CLI restarts.
- **Evidence:** дійсне лише для identity + current run; після terminal state
  воно стає stale.
- **Source data:** read-only snapshot, фізично відокремлений від procedure
  workspace.

Logical thread ID не використовується як сирий checkpoint key — runtime
перетворює його на opaque keyed identifier.

### Налаштування compaction

У starter вже задані такі ліміти токенів:

- target після стискання — **4 000** tokens;
- soft trigger — **8 000** tokens;
- hard input ceiling — **12 000** tokens;
- response reserve — **2 000** tokens.

Ці значення підібрані для коротких synthetic scenarios, а не для production.
Якщо змінюєте їх, збережіть співвідношення `target < soft < hard`, залиште
reserve нижчим за hard ceiling і повторно запустіть compaction needle tests.

Чому не стандартний `SummarizationMiddleware`? У цьому завданні потрібно окремо
потренувати:

- збереження цілісних human/AI/tool message groups;
- атомарну заміну старої history;
- повторне додавання current todo після compaction;
- metadata event, за яким видно, що compaction відбувся.

## Як оцінюється робота

`eval.py` групує детерміновані перевірки у Capability Ledger. Він перевіряє
поведінку системи, а не наявність певних файлів чи класів:

- planning і replanning після dead end;
- repository, monitoring та runbook tools;
- grounding даними з кількох source families;
- compaction без втрати needle context;
- composition та порядок middleware, model/tool call limits;
- атомарність compaction при помилці summarizer і hard-ceiling block;
- recall фактів і процедур між threads;
- evidence-gating без мутації для fact/procedure writes;
- isolation між identities;
- блокування prompt injection;
- видачу evidence, citations і grounded refusal;
- безпечні metadata events.

Core eval детерміновано перевіряє citation integrity, current-run scope і
канонічні synthetic claims. Semantic support довільної free-form відповіді
окремо оцінює лише optional live judge (`eval.py --full`).

- `PASS` — capability спостерігалася під час детермінованого виконання.
- `FAIL` — перевірка не пройшла або потрібну поведінку не вдалося спостерігати.
- `SKIP` — відповідний TODO ще не реалізований.
- `UNAVAILABLE` — недоступний лише optional live signal; це не заміна core.

Deterministic core не потребує API key і є авторитетною частиною оцінювання.
Optional live checks залежать від provider та model і дають лише додатковий
сигнал якості.

Не оптимізуйте код під назву рядка. Якщо capability не пройшов, прочитайте,
якої саме спостережуваної поведінки бракує.

## Модель загроз і правила безпеки

Головне правило: **будь-який зовнішній текст є даними, а не інструкцією**.

До untrusted data належать user input, repository files, monitoring JSON,
runbooks, recalled facts, procedures, summaries, todo text, model output і
provider exceptions. Вони можуть містити prompt injection, control sequences,
завеликі payloads, stale citations або спроби розширити path, URL чи scope.

Готова інфраструктура вже забезпечує:

- доступ лише до allowlisted synthetic resources із перевірених manifests;
- descriptor-relative read-only repository sandbox без symlink traversal;
- monitoring через GET на literal loopback без redirects, proxy чи довільних
  URL;
- атомарний запис процедур із перевіркою конфліктів в окремому private workspace;
- metadata-only events через `AppEvent` і `event_to_public_dict`;
- генерацію identity та secrets через модуль `secrets`;
- відсутність shell execution, довільних imports і production integrations.

Не обходьте ці межі заради простішої реалізації. CLI та UI не повинні показувати
raw source, memory, prompts, tool bodies, provider exceptions або API key.
Chainlit у цій роботі призначений лише для localhost; production authentication,
session model і rate limits залишаються поза межами завдання.


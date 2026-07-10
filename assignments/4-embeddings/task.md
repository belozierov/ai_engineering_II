# Домашнє завдання: Автокатегоризація тікетів через Embeddings

## Завдання

У вас є **300** синтетичних support-тікетів з мітками категорій (поле `category` у `tickets.json`). Вашa мета — побудувати пошуковий пайплайн, який:

1. Перетворює тікети на вектори (embeddings).
2. Кластеризує їх через k-means і візуалізує через t-SNE.
3. Через LLM автоматично називає кожен кластер.
4. Порівнює **BM25** (ключові слова), **cosine** (семантика) і **fusion (RRF)**.
5. Додає **Qdrant `:memory:`** — production vector database без Docker.
6. Використовує **Ticket Helper**: знаходить схожі тікети для нового звернення.

Більша частина коду вже написана. Вам потрібно заповнити **5 TODO** (+ 1 бонус).

---

## Що потрібно зробити

### TODO 1: `get_embeddings(texts)`

Реалізуйте функцію, що перетворює список рядків на матрицю ембедингів.
Використайте модель `"all-MiniLM-L6-v2"` з бібліотеки `sentence-transformers`.

Результат: numpy array shape `(len(texts), 384)`.

---

### TODO 2: `cluster_tickets(embeddings, n_clusters)`

Реалізуйте кластеризацію ембедингів через **k-means** (sklearn). Використайте `random_state=42` для відтворюваності.

Результат: numpy array shape `(n_samples,)` з мітками кластерів `0, 1, …`.

**Підзавдання: знайдіть оптимальне k емпірично.**
Запустіть pipeline для k = 3, 4, 5, 6, 7, 8, 9, 10, 12, запишіть ARI в таблицю у `results.md`. Оберіть k з найвищим ARI і поясніть у висновках: при якому k ARI досягає піку і чому саме там? Що відбувається з кластерами при k менше і більше оптимального?

```bash
uv run starter.py --quick --clusters 5
uv run starter.py --quick --clusters 6
# ... і так для кожного k в таблиці
```

`compute_ari()` вже реалізована — вона виводить ARI після кожного запуску.

---

### TODO 3: `name_cluster(tickets)`

Напишіть промпт, який дає кластеру коротку назву (2–4 слова).

Промпт повинен включати список тікетів і питати LLM про назву. Приклад структури:

```
These are customer support tickets from the same group:
- My laptop screen is flickering...
- Camera autofocus hunts endlessly...

What short category name (2-4 words) best describes this group?
Reply with ONLY the category name, nothing else.
```

**Важливо:** `raise NotImplementedError` вже conditional — він спрацює лише якщо `prompt` порожній. Як тільки ви напишете правильний промпт — raise зникає автоматично.

---

### TODO 4: `bm25_search(corpus, query, top_k)`

Реалізуйте keyword-пошук через **BM25**. Використайте клас `BM25Okapi` з бібліотеки `rank_bm25`.

BM25 ранжує документи за збігом токенів, а не за семантикою — "authenticate" не знайде "login". Саме ця різниця з cosine і є головним takeaway порівняння.

⚠️ Токенізуйте і corpus, і query **однаково** (lowercase + split). Різниця в токенізації — найпоширеніша помилка в цьому завданні.

---

### TODO 5: `upload_to_qdrant(tickets, embeddings)` + `qdrant_search(client, query_emb, top_k)`

**Це найважливіший TODO в цьому завданні.**

Qdrant — production vector database. У режимі `QdrantClient(":memory:")` він запускається повністю in-process без Docker і має той самий API що і cloud-версія.

**`upload_to_qdrant`** — чотири кроки:
1. Створіть клієнт через `QdrantClient(":memory:")`
2. Створіть колекцію з параметрами: `size=384`, `distance=Distance.COSINE`
3. Упакуйте кожен тікет у `PointStruct` з `id`, `vector` та `payload` (текст і категорія)
4. Завантажте через `client.upsert()` і поверніть `client`

**`qdrant_search`** — виклик `client.query_points()` з вектором запиту. Поверніть список `(point.id, point.score)`.

Детальний API — у docstrings `starter.py`. Порівняйте Qdrant з cosine numpy: при 300 тікетах результати майже ідентичні (точний cosine). Різниця у швидкості стає відчутною при 100K+ векторів.

---

## Бонус: `rerank(query, candidates, model_key)`

Порівняйте три cross-encoder моделі на одному запиті:

```bash
uv run starter.py --rerank --query "I can't log into my account"
```

Cross-encoder отримує пару `(query, document)` **разом** і виводить score релевантності — точніше за cosine, але повільніше (один forward pass на пару).

Реалізуйте `rerank()` через клас `CrossEncoder` з `sentence-transformers`. Конфігурація трьох моделей вже є в константі `RERANKER_MODELS` у `starter.py`.

Моделі:
| Ключ | Модель | Розмір | Примітка |
|------|--------|--------|----------|
| `ms-marco` | `cross-encoder/ms-marco-MiniLM-L-6-v2` | 66 MB | Швидка, слабка на коротких текстах |
| `bge-base` | `BAAI/bge-reranker-base` | 270 MB | Краща, лише English |
| `bge-v2-m3` | `BAAI/bge-reranker-v2-m3` | 570 MB | Найкраща, multilingual |

---

## Як запускати

```bash
# Виставити API ключ (лише для TODO 3 — LLM naming)
export OPENROUTER_API_KEY="sk-or-..."

# Перевірка структури (без API викликів)
uv run eval.py

# Швидкий запуск: без LLM naming, 5 демо-запитів
uv run starter.py --quick

# Повний запуск: кластеризація + LLM naming + пошук + Ticket Helper
uv run starter.py

# Один власний запит
uv run starter.py --query "I can't log into my account"

# Бонус: reranker comparison
uv run starter.py --rerank --query "I can't log into my account"

# Змінити кількість кластерів (за замовчуванням 5 — навмисно не оптимально)
uv run starter.py --clusters 9
```

---

## Оцінювання

1. **Структурна перевірка + unit tests**: `uv run eval.py` перевіряє всі 5 TODOs.
2. **Category-recall tests**: для 5 демо-запитів cosine повинен давати ≥3/5 результатів правильної категорії (BM25 ≥2/5). Qdrant перевіряється якщо реалізований.
3. **Результати**: заповніть `results.md` — кластери, таблиці пошуку, Ticket Helper.
4. **Висновки**: відповіді на 5 питань з `results.md`.
5. **Бонус**: reranker таблиця + свій запит.

---

## Файли

| Файл | Призначення |
|------|-------------|
| `starter.py` | Основний файл — ваші 5 TODO + bonus. |
| `eval.py` | Валідація: structural + unit + category-recall tests. |
| `results.md` | Сюди записуєте результати і висновки. |
| `clusters.png` | Генерується автоматично після запуску. |
| `data/tickets.json` | 300 тікетів (спільний датасет від інструктора). |

---

## Вже реалізовано (прочитайте код і docstrings)

- `cosine_search` — brute-force cosine similarity (numpy baseline для порівняння з Qdrant)
- `fusion_search` — Reciprocal Rank Fusion (RRF)
- `compute_ari` — ARI clustering quality score (порівнює ваші кластери з ground-truth категоріями)
- Ticket Helper, t-SNE visualization, comparison table

---

## Часті помилки

| Помилка | Причина | Виправлення |
|---------|---------|-------------|
| BM25 дає інші результати ніж очікується | query не lowercase | Додати `.lower()` і до corpus, і до query |
| `name_cluster` кидає `NotImplementedError` | prompt залишився порожнім | Заповніть рядок `prompt = ""` |
| `get_embeddings` повертає тензор, не numpy | `convert_to_numpy=True` пропущений | Додати параметр до `model.encode()` |
| Qdrant: `PointStruct` приймає float32 | `emb.tolist()` конвертує автоматично | Переконайтесь що викликаєте `.tolist()` |

# Результати: Ops Copilot v2

> Заповніть після виконання домашнього завдання. Не вставляйте API keys,
> повні source bodies, prompt transcripts, PII або реальні production incidents.
> Для ручних перевірок використовуйте `TESTING_SCENARIOS.md`.

## 1. Eval результати

```text
# Вставте вивід:
# uv run --frozen python eval.py
```

**`uv run --frozen pytest`:** PASS / FAIL  

```text
# Якщо запускали live eval:
# uv run --frozen python eval.py --full
```

**Які Capability Ledger рядки були найскладніші довести до PASS і чому?**

_____

## 2. Incident trace

Оберіть **Сценарій 1 або 2** з `TESTING_SCENARIOS.md`. Аналізуйте CLI output за
розділом “Як читати CLI output” у тому самому файлі.

**Запит:**

_____

**Який був план агента?**

_____

**Які source-family events з’явилися і в якому порядку?**

1. _____
2. _____
3. _____

**Які evidence citations потрапили у фінальну відповідь?**

_____

**Які `evidence=...` з Activity збіглися з citations у відповіді?**

_____

## 3. Evidence & grounding

**Чим `evidence_id` відрізняється від `source_id`?**

_____

**Наведіть приклад, коли агент мав відмовитись замість відповіді. Чому?**

_____

**Чому recalled memory або procedure не можна цитувати як current-run evidence?**

_____

## 4. Safety probes

Оберіть мінімум **2 probes зі Сценаріїв 3–6** у `TESTING_SCENARIOS.md`.

### Probe 1

**Що запустили?**

_____

**Що сталося?**

_____

**Чому це правильна або неправильна поведінка?**

_____

### Probe 2

**Що запустили?**

_____

**Що сталося?**

_____

**Чому це правильна або неправильна поведінка?**

_____

## 5. Рефлексія

**Який TODO був найскладніший і чому?**

_____

**Де eval або ручний сценарій змусив вас змінити реалізацію?**

_____

**Що б ви зробили інакше у production-версії такого агента?**

_____

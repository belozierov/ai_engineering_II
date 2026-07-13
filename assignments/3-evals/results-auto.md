# Результати — HW: Eval Pipeline для TechStore Support Agent (Swift)

**Агент:** `claude-haiku-4-5` (через `claude -p`, без інструментів)
**Суддя:** `claude-opus-4-8`
**Режим:** full (synthetic + quality judge + safety judge)

- Якісних кейсів: 14 (6 seed + 8 synthetic)
- Adversarial кейсів: 6
- Викликів моделі: 121 · Орієнтовна вартість: $1.1136

## Порівняння A/B/C

```text
==============================================================================
  A/B/C Comparison
==============================================================================
  Metric                Prompt A    Prompt B    Prompt C    Best  
  --------------------------------------------------------------------------
  required_keywords     0.68        0.76        0.71        B     
  forbidden_keywords    1.00        1.00        1.00        —     
  must_offer            0.49        0.56        0.49        B     
  empathy               3.79        4.64        4.29        B     
  solution_quality      4.00        4.14        4.00        B     
  professionalism       4.86        4.79        4.86        —     
  accuracy              4.21        3.29        5.00        C     
  conciseness_relevance 4.00        3.79        4.36        C     
  safety                1.00        0.67        1.00        —     
  --------------------------------------------------------------------------
  composite (0-1)       0.82        0.79        0.86        
==============================================================================
  WINNER: Prompt B  (won 4/9 metrics, composite=0.79)
==============================================================================
```

## Аналіз A/B/C
- **empathy:** A=3.79 · B=4.64 · C=4.29
- **accuracy:** A=4.21 · B=3.29 · C=5.00
- **safety:** A=1.00 · B=0.67 · C=1.00

**Висновок:** WINNER — Prompt B (виграв 4/9 метрик, composite=0.79).

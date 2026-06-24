# Результати — HW: Eval Pipeline для TechStore Support Agent (Swift)

**Агент:** `claude-haiku-4-5` (через `claude -p`, без інструментів)
**Суддя:** `claude-opus-4-8`
**Режим:** full (synthetic + quality judge + safety judge)

- Якісних кейсів: 14 (6 seed + 8 synthetic)
- Adversarial кейсів: 6
- Викликів моделі: 121 · Орієнтовна вартість: $1.1243

## Порівняння A/B/C

```text
==============================================================================
  A/B/C Comparison
==============================================================================
  Metric                Prompt A    Prompt B    Prompt C    Best  
  --------------------------------------------------------------------------
  required_keywords     0.86        1.00        0.93        B     
  forbidden_keywords    1.00        1.00        1.00        —     
  must_offer            0.93        1.00        0.86        B     
  empathy               3.71        4.57        4.07        B     
  solution_quality      4.29        4.07        4.00        A     
  professionalism       4.86        4.64        5.00        C     
  accuracy              4.64        3.57        5.00        C     
  conciseness_relevance 4.14        3.71        4.21        C     
  safety                1.00        0.67        1.00        —     
  --------------------------------------------------------------------------
  composite (0-1)       0.90        0.86        0.92        
==============================================================================
  WINNER: Prompt C  (won 3/9 metrics, composite=0.92)
==============================================================================
```

## Аналіз A/B/C
- **empathy:** A=3.71 · B=4.57 · C=4.07
- **accuracy:** A=4.64 · B=3.57 · C=5.00
- **safety:** A=1.00 · B=0.67 · C=1.00

**Висновок:** WINNER — Prompt C (виграв 3/9 метрик, composite=0.92).

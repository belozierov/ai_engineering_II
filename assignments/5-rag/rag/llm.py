"""Direct OpenRouter completion helper (pre-built).

Used by tools that need an auxiliary LLM call (query rewriting, LLM-as-judge).
The main agent reasoning goes through Pydantic AI; this is for tool-internal
calls. Requires the OPENROUTER_API_KEY environment variable.
"""

from __future__ import annotations

import os
import time

import httpx

from . import config


def llm_complete(prompt: str, temperature: float = 0.0, timeout: float = 30.0, max_retries: int = 4) -> str:
    """Send a single-turn prompt to OpenRouter and return the text response.

    Retries with exponential backoff on 429 (rate limit) and 5xx, honouring the
    Retry-After header when present. This keeps a burst of demo queries from
    failing when the free-tier rate limit is briefly exceeded.
    """
    api_key = os.environ.get("OPENROUTER_API_KEY", "")
    if not api_key:
        raise RuntimeError("OPENROUTER_API_KEY environment variable is not set")

    delay = 1.0
    for attempt in range(max_retries + 1):
        response = httpx.post(
            config.OPENROUTER_API_URL,
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            json={
                "model": config.OPENROUTER_MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": temperature,
            },
            timeout=timeout,
        )
        if response.status_code == 429 or response.status_code >= 500:
            if attempt < max_retries:
                retry_after = response.headers.get("retry-after")
                time.sleep(float(retry_after) if retry_after else delay)
                delay = min(delay * 2, 8.0)
                continue
        response.raise_for_status()
        return response.json()["choices"][0]["message"]["content"].strip()

    response.raise_for_status()  # retries exhausted on 429/5xx
    return response.json()["choices"][0]["message"]["content"].strip()

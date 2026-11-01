"""LLM providers. NoneProvider is the default; HTTP providers ask the budget
ledger first, so with the $0 defaults they never send a request."""

from __future__ import annotations

import json
import os
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

from jsonschema import Draft202012Validator

from agents.llm.base import Provider
from agents.llm.budget import BudgetLedger, BudgetRefused

REQUEST_TIMEOUT_SECONDS = 60


class NoneProvider(Provider):
    """Default: no LLM; always returns None."""

    mode = "none"

    def complete(self, prompt, schema, inputs):
        return None


class FakeProvider(Provider):
    """Test double: returns the queued RESPONSES in order (None when empty)
    and records every call in .calls."""

    mode = "none"
    model = "fake"

    def __init__(self, responses: Optional[List[Optional[Dict[str, Any]]]] = None):
        self.responses = list(responses or [])
        self.calls: List[Dict[str, Any]] = []

    def complete(self, prompt, schema, inputs):
        self.calls.append({"prompt": prompt, "schema": schema, "inputs": inputs})
        if not self.responses:
            return None
        resp = self.responses.pop(0)
        if resp is not None and schema and list(Draft202012Validator(schema).iter_errors(resp)):
            return None
        return resp


class _ChatProvider(Provider):
    """OpenAI-compatible /v1/chat/completions client (temperature 0)."""

    price_env = "LLM_PRICE_PER_1K_TOKENS_USD"

    def __init__(self, base_url: str, model: str, api_key: Optional[str] = None,
                 ledger: Optional[BudgetLedger] = None, max_tokens: int = 512):
        self.base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self.ledger = ledger or BudgetLedger()
        self.max_tokens = max_tokens

    def _price_per_1k(self) -> float:
        try:
            return max(float(os.environ.get(self.price_env, self.default_price)), 0.0)
        except ValueError:
            return self.default_price

    def estimate(self, prompt: str, inputs: Dict[str, Any]) -> Tuple[int, float]:
        tokens = (len(prompt) + len(json.dumps(inputs, default=str))) // 4 + self.max_tokens
        return tokens, tokens / 1000.0 * self._price_per_1k()

    def complete(self, prompt, schema, inputs):
        tokens, cost = self.estimate(prompt, inputs)
        try:
            self.ledger.authorize(self.mode, cost)  # before any HTTP request
        except BudgetRefused:
            return None
        body = json.dumps({
            "model": self.model, "temperature": 0, "seed": 0, "max_tokens": self.max_tokens,
            "messages": [
                {"role": "system", "content": "Answer with JSON only, matching this schema: " + json.dumps(schema)},
                {"role": "user", "content": prompt + "\n\nInputs:\n" + json.dumps(inputs, default=str)},
            ],
        }).encode()
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = "Bearer " + self._api_key
        req = urllib.request.Request(self.base_url + "/v1/chat/completions", data=body, headers=headers, method="POST")
        self.ledger.record(self.mode, self.model, tokens, cost)
        try:
            with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECONDS) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            out = json.loads(payload["choices"][0]["message"]["content"])
        except Exception:  # network, HTTP or parse failure: deterministic fallback
            return None
        if schema and list(Draft202012Validator(schema).iter_errors(out)):
            return None
        return out

    def __repr__(self):
        return "%s(base_url=%r, model=%r, api_key=%s)" % (
            type(self).__name__, self.base_url, self.model, "<set>" if self._api_key else "<none>")


class OllamaProvider(_ChatProvider):
    """Local Ollama (OpenAI-compatible); $0 but still counted per run."""

    mode = "ollama"
    default_price = 0.0

    def __init__(self, base_url: str = "http://127.0.0.1:11434", model: str = "qwen2.5:7b", **kw):
        super().__init__(base_url, model, **kw)

    def _price_per_1k(self) -> float:
        return 0.0


class OpenAICompatibleProvider(_ChatProvider):
    """Any OpenAI-compatible cloud endpoint; needs LLM_MONTHLY_BUDGET_USD > 0."""

    mode = "cloud"
    default_price = 0.01


def get_provider() -> Provider:
    """Provider selected by LLM_PROVIDER (none | fake | ollama | openai; default none)."""
    name = (os.environ.get("LLM_PROVIDER") or "none").strip().lower()
    if name == "ollama":
        return OllamaProvider(
            base_url=os.environ.get("LLM_BASE_URL") or "http://127.0.0.1:11434",
            model=os.environ.get("LLM_MODEL") or "qwen2.5:7b",
        )
    if name in ("openai", "cloud", "openai_compatible"):
        return OpenAICompatibleProvider(
            base_url=os.environ.get("LLM_BASE_URL") or "https://api.openai.com",
            model=os.environ.get("LLM_MODEL") or "gpt-4o-mini",
            api_key=os.environ.get("LLM_API_KEY") or None,
        )
    if name == "fake":
        return FakeProvider()
    return NoneProvider()

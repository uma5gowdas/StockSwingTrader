"""LLM provider interface (six-agent plan section 5.7). No LLM is used in
Phase 0-1; the default provider is NoneProvider."""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Dict, Optional


class Provider(ABC):
    """An LLM backend. complete() returns a dict that matches SCHEMA, or None
    (the caller then uses its deterministic logic)."""

    #: "none", "ollama" or "cloud" (envelope llm.mode)
    mode = "none"
    model: Optional[str] = None

    @abstractmethod
    def complete(self, prompt: str, schema: Dict[str, Any], inputs: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Structured completion of PROMPT over INPUTS, validated against SCHEMA."""

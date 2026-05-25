#!/usr/bin/env python3
"""
LingNet Agent OS V2.2 — Condenser Engine
LLM context compression pipeline for cognitive bridge.

Implements:
- Token counting (tiktoken-compatible fallback)
- Message deduplication
- Sliding window truncation
- Importance-based summarization trigger
- Compression ratio tracking
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class CompressionStrategy(Enum):
    """Context compression strategies."""
    NONE = "none"                    # No compression
    DEDUP = "dedup"                  # Remove duplicate messages
    SLIDING_WINDOW = "sliding_window"  # Keep last N tokens
    SUMMARIZE = "summarize"          # LLM-based summarization
    HYBRID = "hybrid"                # Dedup + window + summarize


@dataclass
class Message:
    """Single conversation message."""
    role: str          # "user", "assistant", "system", "tool"
    content: str
    timestamp: float = field(default_factory=time.time)
    token_count: int = 0
    importance: float = 1.0   # 0.0-1.0, higher = more important

    def __post_init__(self):
        if self.token_count == 0:
            self.token_count = self._estimate_tokens()

    def _estimate_tokens(self) -> int:
        """Rough token estimation (4 chars/token for English, 2 for CJK)."""
        text = self.content
        # Simple heuristic: count whitespace-separated words + punctuation
        return max(1, len(text) // 4)

    def fingerprint(self) -> str:
        """Content fingerprint for dedup."""
        return hashlib.md5(f"{self.role}:{self.content}".encode()).hexdigest()[:12]


@dataclass
class CondenserInput:
    """Input to the condenser pipeline."""
    messages: list[Message]
    max_tokens: int = 4096
    strategy: CompressionStrategy = CompressionStrategy.HYBRID
    preserve_system: bool = True     # Never compress system messages
    min_messages: int = 2            # Always keep at least N messages


@dataclass
class CondenserOutput:
    """Output from the condenser pipeline."""
    messages: list[Message]
    original_tokens: int
    compressed_tokens: int
    tokens_saved: int
    compression_ratio: float        # 1.0 = no compression, 0.5 = half size
    strategy_used: CompressionStrategy
    processing_time_ms: float

    @property
    def was_compressed(self) -> bool:
        return self.tokens_saved > 0


class Condenser:
    """
    LLM context compression engine.
    
    Pipeline:
    1. Deduplicate identical messages
    2. Apply sliding window (keep recent + important)
    3. Trigger summarization if still over budget
    """

    def __init__(self, strategy: CompressionStrategy = CompressionStrategy.HYBRID):
        self.strategy = strategy
        self._total_compressed = 0
        self._total_saved = 0

    def condense(self, inp: CondenserInput) -> CondenserOutput:
        """Run the full compression pipeline."""
        start = time.monotonic()
        original_tokens = sum(m.token_count for m in inp.messages)

        messages = list(inp.messages)

        # Step 1: Dedup
        if self.strategy in (CompressionStrategy.DEDUP, CompressionStrategy.HYBRID):
            messages = self._dedup(messages, inp.preserve_system)

        # Step 2: Sliding window
        if self.strategy in (CompressionStrategy.SLIDING_WINDOW, CompressionStrategy.HYBRID):
            messages = self._sliding_window(
                messages, inp.max_tokens, inp.preserve_system, inp.min_messages
            )

        # Step 3: Summarize (if still over budget)
        if self.strategy in (CompressionStrategy.SUMMARIZE, CompressionStrategy.HYBRID):
            current_tokens = sum(m.token_count for m in messages)
            if current_tokens > inp.max_tokens:
                messages = self._summarize_trigger(messages, inp.max_tokens)

        compressed_tokens = sum(m.token_count for m in messages)
        tokens_saved = original_tokens - compressed_tokens
        ratio = compressed_tokens / max(original_tokens, 1)

        elapsed = (time.monotonic() - start) * 1000

        self._total_compressed += 1
        self._total_saved += tokens_saved

        return CondenserOutput(
            messages=messages,
            original_tokens=original_tokens,
            compressed_tokens=compressed_tokens,
            tokens_saved=tokens_saved,
            compression_ratio=ratio,
            strategy_used=self.strategy,
            processing_time_ms=elapsed,
        )

    def _dedup(self, messages: list[Message], preserve_system: bool) -> list[Message]:
        """Remove duplicate messages (same role + content)."""
        seen: set[str] = set()
        result: list[Message] = []
        for msg in messages:
            if preserve_system and msg.role == "system":
                result.append(msg)
                continue
            fp = msg.fingerprint()
            if fp not in seen:
                seen.add(fp)
                result.append(msg)
        return result

    def _sliding_window(
        self,
        messages: list[Message],
        max_tokens: int,
        preserve_system: bool,
        min_messages: int,
    ) -> list[Message]:
        """Keep most recent + important messages within token budget."""
        total = sum(m.token_count for m in messages)
        if total <= max_tokens:
            return messages

        # Separate system messages
        system_msgs = [m for m in messages if m.role == "system"] if preserve_system else []
        other_msgs = [m for m in messages if m.role != "system" or not preserve_system]

        system_tokens = sum(m.token_count for m in system_msgs)
        budget = max_tokens - system_tokens

        # Sort by importance (desc) then by recency (desc)
        scored = [(m, m.importance * 0.6 + (m.timestamp / 1e12) * 0.4) for m in other_msgs]
        scored.sort(key=lambda x: x[1], reverse=True)

        kept: list[Message] = []
        used = 0
        for msg, _score in scored:
            if used + msg.token_count <= budget and len(kept) < len(other_msgs):
                kept.append(msg)
                used += msg.token_count
            if len(kept) >= min_messages and used >= budget * 0.9:
                break

        # Restore chronological order
        kept.sort(key=lambda m: m.timestamp)

        return system_msgs + kept

    def _summarize_trigger(
        self, messages: list[Message], max_tokens: int
    ) -> list[Message]:
        """
        Trigger LLM-based summarization for old messages.
        In V2.2, this calls back into Zig via CFFI.
        Placeholder: just truncate aggressively.
        """
        total = sum(m.token_count for m in messages)
        if total <= max_tokens:
            return messages

        # Aggressive truncation: keep first (system) + last 3
        if len(messages) > 4:
            return messages[:1] + messages[-3:]
        return messages

    def get_stats(self) -> dict:
        """Return compression statistics."""
        return {
            "total_compressed": self._total_compressed,
            "total_tokens_saved": self._total_saved,
            "avg_savings": self._total_saved / max(self._total_compressed, 1),
        }


# ─── CLI / Self-test ─────────────────────────────────────────────────

if __name__ == "__main__":
    # Demo: compress a conversation
    messages = [
        Message(role="system", content="You are a helpful AI assistant."),
        Message(role="user", content="Hello!"),
        Message(role="assistant", content="Hi! How can I help you?"),
        Message(role="user", content="Hello!"),  # duplicate
        Message(role="assistant", content="Hi! How can I help you?"),  # duplicate
        Message(role="user", content="What's the weather like?"),
        Message(role="assistant", content="I don't have real-time weather data."),
        Message(role="user", content="Tell me about quantum computing."),
        Message(role="assistant", content="Quantum computing uses qubits..." * 50),
    ]

    condenser = Condenser(strategy=CompressionStrategy.HYBRID)
    result = condenser.condense(CondenserInput(
        messages=messages,
        max_tokens=200,
        strategy=CompressionStrategy.HYBRID,
    ))

    print(f"Original: {result.original_tokens} tokens ({len(messages)} messages)")
    print(f"Compressed: {result.compressed_tokens} tokens ({len(result.messages)} messages)")
    print(f"Saved: {result.tokens_saved} tokens ({1 - result.compression_ratio:.0%} reduction)")
    print(f"Strategy: {result.strategy_used.value}")
    print(f"Time: {result.processing_time_ms:.2f}ms")
    print(f"\nStats: {condenser.get_stats()}")

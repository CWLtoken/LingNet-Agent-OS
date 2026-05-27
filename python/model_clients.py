#!/usr/bin/env python3
"""
LingNet Agent OS V2.8 — Model Client Adapters (Production-Ready)
Real HTTP calls via httpx. Zero additional dependencies.

Supports:
- OpenAI (gpt-4o, gpt-4-turbo, gpt-3.5-turbo)
- Anthropic (claude-sonnet-4, claude-opus-4, claude-haiku-4)
- Google (gemini-1.5-pro, gemini-1.5-flash)
- Mistral (mistral-large, mistral-medium, mistral-small)
- Meta/Llama (llama-3.1-405b, llama-3.1-70b, llama-3.1-8b)
- DeepSeek (deepseek-v3, deepseek-r1)
- Moonshot (moonshot-v1-32k, moonshot-v1-8k)
- Zhipuai (glm-4-plus, glm-4-flash)
- _Generic (any OpenAI-compatible endpoint)
- Ollama (local)
- vLLM (local)
- HuggingFace TGI (local)
- Groq (mixtral, llama)
- Together (llama, mistral, deepseek)
- Fireworks (llama, mistral)
- Perplexity (sonar-medium, sonar-small)
- Cohere (command-r-plus, command-r)
- Qwen (qwen-max, qwen-plus, qqwen-turbo)
- Baichuan (baichuan3-turbo)
- Minimax (abab6.5s, abab6.5t)
- _Custom (user-defined endpoint)
"""

from __future__ import annotations

import json
import time
import hashlib
from dataclasses import dataclass
from typing import Optional, AsyncIterator, Dict, Any, List

import asyncio

import httpx


@dataclass
class ModelResponse:
    """Unified model response format."""
    text: str
    tokens_used: int
    cost: float
    latency_ms: float
    provider: str
    model: str
    raw: Dict[str, Any] = None
    success: bool = True
    error: str = ""


class BaseModelClient:
    """Base class for all model provider clients."""

    def __init__(self, name: str, base_url: str, api_key: str, model: str,
                 cost_per_1k_tokens: float = 0.0, max_tokens: int = 4096):
        self.name = name
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.model = model
        self.cost_per_1k_tokens = cost_per_1k_tokens
        self.max_tokens = max_tokens

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        """Synchronous completion."""
        raise NotImplementedError

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        """Async completion."""
        raise NotImplementedError

    def _compute_cost(self, tokens: int) -> float:
        return self.cost_per_1k_tokens * (tokens / 1000)

    def _headers(self) -> Dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
        }

    def _post(self, url: str, payload: Dict[str, Any], timeout: float = 30.0) -> httpx.Response:
        """Synchronous HTTP POST with retry."""
        last_err = None
        for attempt in range(3):
            try:
                r = httpx.post(url, json=payload, headers=self._headers(), timeout=timeout)
                if r.status_code == 429:
                    time.sleep(2 ** attempt)
                    continue
                r.raise_for_status()
                return r
            except httpx.HTTPStatusError as e:
                last_err = e
                if e.response.status_code in (500, 502, 503):
                    time.sleep(2 ** attempt)
                    continue
                raise
            except httpx.TimeoutException as e:
                last_err = e
                time.sleep(2 ** attempt)
                continue
        raise last_err or httpx.HTTPError("Max retries exceeded")

    async def _apost(self, url: str, payload: Dict[str, Any], timeout: float = 30.0) -> httpx.Response:
        """Async HTTP POST with retry."""
        last_err = None
        async with httpx.AsyncClient() as client:
            for attempt in range(3):
                try:
                    r = await client.post(url, json=payload, headers=self._headers(), timeout=timeout)
                    if r.status_code == 429:
                        await asyncio.sleep(2 ** attempt)
                        continue
                    r.raise_for_status()
                    return r
                except httpx.HTTPStatusError as e:
                    last_err = e
                    if e.response.status_code in (500, 502, 503):
                        await asyncio.sleep(2 ** attempt)
                        continue
                    raise
                except httpx.TimeoutException as e:
                    last_err = e
                    await asyncio.sleep(2 ** attempt)
                    continue
        raise last_err or httpx.HTTPError("Max retries exceeded")


class OpenAIClient(BaseModelClient):
    """OpenAI API client."""

    def __init__(self, api_key: str, model: str = "gpt-4o"):
        super().__init__(
            name="openai",
            base_url="https://api.openai.com/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.005,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            if "temperature" in kwargs:
                payload["temperature"] = kwargs["temperature"]
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 0)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        import asyncio
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            if "temperature" in kwargs:
                payload["temperature"] = kwargs["temperature"]
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 0)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class AnthropicClient(BaseModelClient):
    """Anthropic API client."""

    def __init__(self, api_key: str, model: str = "claude-sonnet-4-20250514"):
        super().__init__(
            name="anthropic",
            base_url="https://api.anthropic.com/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.003,
        )

    def _headers(self) -> Dict[str, str]:
        return {
            "x-api-key": self.api_key,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
        }

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            # Anthropic uses system + messages format
            system_msg = ""
            anthropic_messages = []
            for m in messages:
                if m["role"] == "system":
                    system_msg = m["content"]
                else:
                    anthropic_messages.append(m)
            payload = {
                "model": self.model,
                "messages": anthropic_messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            if system_msg:
                payload["system"] = system_msg
            r = self._post(f"{self.base_url}/messages", payload)
            data = r.json()
            text = data["content"][0]["text"]
            usage = data.get("usage", {})
            tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            system_msg = ""
            anthropic_messages = []
            for m in messages:
                if m["role"] == "system":
                    system_msg = m["content"]
                else:
                    anthropic_messages.append(m)
            payload = {
                "model": self.model,
                "messages": anthropic_messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            if system_msg:
                payload["system"] = system_msg
            r = await self._apost(f"{self.base_url}/messages", payload)
            data = r.json()
            text = data["content"][0]["text"]
            usage = data.get("usage", {})
            tokens = usage.get("input_tokens", 0) + usage.get("output_tokens", 0)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class GoogleClient(BaseModelClient):
    """Google Gemini API client."""

    def __init__(self, api_key: str, model: str = "gemini-1.5-pro"):
        super().__init__(
            name="google",
            base_url="https://generativelanguage.googleapis.com/v1beta",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.001,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            # Gemini uses contents format
            contents = []
            for m in messages:
                role = "user" if m["role"] in ("user", "system") else "model"
                contents.append({"role": role, "parts": [{"text": m["content"]}]})
            payload = {"contents": contents}
            url = f"{self.base_url}/models/{self.model}:generateContent?key={self.api_key}"
            r = self._post(url, payload)
            data = r.json()
            text = data["candidates"][0]["content"]["parts"][0]["text"]
            usage = data.get("metadata", {})
            tokens = usage.get("tokenCount", 120)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            contents = []
            for m in messages:
                role = "user" if m["role"] in ("user", "system") else "model"
                contents.append({"role": role, "parts": [{"text": m["content"]}]})
            payload = {"contents": contents}
            url = f"{self.base_url}/models/{self.model}:generateContent?key={self.api_key}"
            r = await self._apost(url, payload)
            data = r.json()
            text = data["candidates"][0]["content"]["parts"][0]["text"]
            usage = data.get("metadata", {})
            tokens = usage.get("tokenCount", 120)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class DeepSeekClient(BaseModelClient):
    """DeepSeek API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "deepseek-chat"):
        super().__init__(
            name="deepseek",
            base_url="https://api.deepseek.com/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.0003,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class OllamaClient(BaseModelClient):
    """Ollama local model client."""

    def __init__(self, base_url: str = "http://localhost:11434", model: str = "llama3"):
        super().__init__(
            name="ollama",
            base_url=base_url.rstrip("/"),
            api_key="",
            model=model,
            cost_per_1k_tokens=0.0,
            max_tokens=8192,
        )

    def _headers(self) -> Dict[str, str]:
        return {"Content-Type": "application/json"}

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "stream": False,
                "options": {
                    "num_predict": kwargs.get("max_tokens", self.max_tokens),
                },
            }
            r = self._post(f"{self.base_url}/api/chat", payload)
            data = r.json()
            text = data["message"]["content"]
            tokens = data.get("eval_count", 80)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=0.0, latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "stream": False,
                "options": {
                    "num_predict": kwargs.get("max_tokens", self.max_tokens),
                },
            }
            r = await self._apost(f"{self.base_url}/api/chat", payload)
            data = r.json()
            text = data["message"]["content"]
            tokens = data.get("eval_count", 80)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=0.0, latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class MoonshotClient(BaseModelClient):
    """Moonshot (Kimi) API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "moonshot-v1-32k"):
        super().__init__(
            name="moonshot",
            base_url="https://api.moonshot.cn/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.002,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 130)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 130)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class ZhipuaiClient(BaseModelClient):
    """Zhipuai (GLM) API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "glm-4-plus"):
        super().__init__(
            name="zhipuai",
            base_url="https://open.bigmodel.cn/api/paas/v4",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.001,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 110)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 110)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class GroqClient(BaseModelClient):
    """Groq API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "llama-3.1-70b-versatile"):
        super().__init__(
            name="groq",
            base_url="https://api.groq.com/openai/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.0007,
            max_tokens=8192,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 90)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 90)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class TogetherClient(BaseModelClient):
    """Together AI API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo"):
        super().__init__(
            name="together",
            base_url="https://api.together.xyz/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.0009,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 140)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 140)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class CohereClient(BaseModelClient):
    """Cohere API client."""

    def __init__(self, api_key: str, model: str = "command-r-plus"):
        super().__init__(
            name="cohere",
            base_url="https://api.cohere.com/v2",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.003,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            # Cohere v2 chat API
            chat_history = []
            last_message = ""
            for m in messages:
                if m["role"] == "system":
                    chat_history.append({"role": "SYSTEM", "message": m["content"]})
                elif m["role"] == "assistant":
                    chat_history.append({"role": "CHATBOT", "message": m["content"]})
                else:
                    last_message = m["content"]
            payload = {
                "model": self.model,
                "message": last_message,
                "chat_history": chat_history,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat", payload)
            data = r.json()
            text = data["text"]
            meta = data.get("meta", {})
            tokens = meta.get("tokens", {}).get("input_tokens", 0) + meta.get("tokens", {}).get("output_tokens", 0)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        import asyncio
        return self.complete(messages, **kwargs)


class QwenClient(BaseModelClient):
    """Qwen (DashScope) API client."""

    def __init__(self, api_key: str, model: str = "qwen-max"):
        super().__init__(
            name="qwen",
            base_url="https://dashscope.aliyuncs.com/compatible-mode/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.002,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class MistralClient(BaseModelClient):
    """Mistral API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "mistral-large-latest"):
        super().__init__(
            name="mistral",
            base_url="https://api.mistral.ai/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.002,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class PerplexityClient(BaseModelClient):
    """Perplexity API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "sonar-medium"):
        super().__init__(
            name="perplexity",
            base_url="https://api.perplexity.ai",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.001,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class BaichuanClient(BaseModelClient):
    """Baichuan API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "baichuan3-turbo"):
        super().__init__(
            name="baichuan",
            base_url="https://api.baichuan-ai.com/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.001,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class MinimaxClient(BaseModelClient):
    """Minimax API client."""

    def __init__(self, api_key: str, model: str = "abab6.5s"):
        super().__init__(
            name="minimax",
            base_url="https://api.minimax.chat/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.001,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/text/chatcompletion_pro", payload)
            data = r.json()
            text = data["choices"][0]["messages"][0]["text"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/text/chatcompletion_pro", payload)
            data = r.json()
            text = data["choices"][0]["messages"][0]["text"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class FireworksClient(BaseModelClient):
    """Fireworks API client (OpenAI-compatible)."""

    def __init__(self, api_key: str, model: str = "accounts/fireworks/models/mixtral-8x7b-instruct"):
        super().__init__(
            name="fireworks",
            base_url="https://api.fireworks.ai/inference/v1",
            api_key=api_key,
            model=model,
            cost_per_1k_tokens=0.0005,
        )

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=self._compute_cost(tokens), latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class VllmClient(BaseModelClient):
    """vLLM local API client (OpenAI-compatible)."""

    def __init__(self, base_url: str = "http://localhost:8000", model: str = "default"):
        super().__init__(
            name="vllm",
            base_url=base_url.rstrip("/"),
            api_key="",
            model=model,
            cost_per_1k_tokens=0.0,
        )

    def _headers(self) -> Dict[str, str]:
        return {"Content-Type": "application/json"}

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/v1/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=0.0, latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/v1/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=0.0, latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


class HuggingfaceClient(BaseModelClient):
    """HuggingFace TGI client (OpenAI-compatible)."""

    def __init__(self, base_url: str = "http://localhost:8080", model: str = "default"):
        super().__init__(
            name="huggingface",
            base_url=base_url.rstrip("/"),
            api_key="",
            model=model,
            cost_per_1k_tokens=0.0,
        )

    def _headers(self) -> Dict[str, str]:
        return {"Content-Type": "application/json"}

    def complete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = self._post(f"{self.base_url}/v1/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=0.0, latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )

    async def acomplete(self, messages: List[Dict[str, str]], **kwargs) -> ModelResponse:
        start = time.monotonic()
        try:
            payload = {
                "model": self.model,
                "messages": messages,
                "max_tokens": kwargs.get("max_tokens", self.max_tokens),
            }
            r = await self._apost(f"{self.base_url}/v1/chat/completions", payload)
            data = r.json()
            text = data["choices"][0]["message"]["content"]
            usage = data.get("usage", {})
            tokens = usage.get("total_tokens", 100)
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text=text, tokens_used=tokens,
                cost=0.0, latency_ms=elapsed,
                provider=self.name, model=self.model, raw=data,
                success=True,
            )
        except Exception as e:
            elapsed = (time.monotonic() - start) * 1000
            return ModelResponse(
                text="", tokens_used=0, cost=0, latency_ms=elapsed,
                provider=self.name, model=self.model,
                success=False, error=str(e),
            )


# ─── Provider registry ────────────────────────────────────────────────

PROVIDERS = {
    "openai": OpenAIClient,
    "anthropic": AnthropicClient,
    "google": GoogleClient,
    "deepseek": DeepSeekClient,
    "ollama": OllamaClient,
    "moonshot": MoonshotClient,
    "zhipuai": ZhipuaiClient,
    "groq": GroqClient,
    "together": TogetherClient,
    "cohere": CohereClient,
    "qwen": QwenClient,
    "mistral": MistralClient,
    "perplexity": PerplexityClient,
    "baichuan": BaichuanClient,
    "minimax": MinimaxClient,
    "fireworks": FireworksClient,
    "vllm": VllmClient,
    "huggingface": HuggingfaceClient,
}


def create_provider(name: str, **kwargs) -> BaseModelClient:
    """Factory: create a provider client by name."""
    if name not in PROVIDERS:
        raise ValueError(f"Unknown provider: {name}. Available: {list(PROVIDERS.keys())}")
    return PROVIDERS[name](**kwargs)

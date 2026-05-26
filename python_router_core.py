#!/usr/bin/env python3
"""
LingNet Agent OS V2.2 - Multi-Model Router Core (Python Layer)
===============================================================
Responsibility Boundary (per V2.2 Architecture Decision):
- Zig Layer: Config validation, MRC routing, request queuing, timeout control, error stats
- Python Layer (this file): HTTP client implementation, token counting, cost calculation,
                            smart routing strategy, race result merging

Performance Target: Race mode first response < 2s, Smart routing P99 < 3s
"""

import logging
import threading

logger = logging.getLogger(__name__)
import asyncio
import time
import json
from typing import Dict, List, Optional, Any, Callable
from dataclasses import dataclass, field
from enum import Enum
from concurrent.futures import FIRST_COMPLETED
import aiohttp
import tiktoken


class RoutingStrategy(Enum):
    RACE = "race"           # Take first successful response
    SMART = "smart"       # Weighted distribution
    UNIFORM = "uniform"   # Round-robin


@dataclass
class ModelProvider:
    id: str
    name: str
    endpoint: str
    api_key: str
    api_compat: str  # "openai", "anthropic", "google"
    models: List[Dict[str, Any]]
    weight: int = 0  # For smart routing
    latency_ms: float = 0.0  # Running average
    error_rate: float = 0.0  # Running average

    def get_model_config(self, model_id: str) -> Optional[Dict]:
        for m in self.models:
            if m["id"] == model_id:
                return m
        return None


@dataclass
class RoutingConfig:
    strategy: RoutingStrategy
    fallback_strategy: Optional[RoutingStrategy]
    budget_per_hour: float
    candidates: List[str]  # "provider/model" format
    weights: Dict[str, int]  # provider -> weight for smart routing
    retry_count: int = 2
    retry_delay_ms: int = 1000
    retry_on_errors: List[str] = field(default_factory=lambda: ["timeout", "rate_limit", "server_error"])
    race_timeout_ms: int = 5000
    collect_all: bool = False


@dataclass
class LLMRequest:
    messages: List[Dict[str, str]]
    model: str
    provider: str
    temperature: float = 0.7
    max_tokens: Optional[int] = None
    stream: bool = False


@dataclass
class LLMResponse:
    content: str
    provider: str
    model: str
    latency_ms: float
    tokens_in: int
    tokens_out: int
    cost_usd: float
    finish_reason: str
    error: Optional[str] = None


class CostTracker:
    """Real-time cost tracking with hourly budget enforcement."""

    def __init__(self, hourly_budget: float):
        self.hourly_budget = hourly_budget
        self.hourly_spent = 0.0
        self.hour_start = time.time()
        # P0-7 FIX: threading.Lock for thread safety (asyncio.Lock only protects against coroutine interleaving)
        self._lock = threading.Lock()

    async def charge(self, cost: float) -> bool:
        # P0-7 FIX: Use threading.Lock for thread safety
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self._charge_sync, cost)

    def _charge_sync(self, cost: float) -> bool:
        with self._lock:
            # Reset hour if needed
            if time.time() - self.hour_start > 3600:
                self.hour_start = time.time()
                self.hourly_spent = 0.0

            if self.hourly_spent + cost > self.hourly_budget:
                return False  # Budget exceeded

            self.hourly_spent += cost
            return True

    def get_stats(self) -> Dict[str, float]:
        return {
            "hourly_budget": self.hourly_budget,
            "hourly_spent": self.hourly_spent,
            "remaining": self.hourly_budget - self.hourly_spent,
            "usage_percent": (self.hourly_spent / self.hourly_budget) * 100,
        }


class TokenCounter:
    """Cross-provider token counting using tiktoken where available."""

    def __init__(self):
        self.encoders: Dict[str, Any] = {}

    def count_tokens(self, text: str, model: str) -> int:
        # Try tiktoken for OpenAI-compatible models
        if "gpt-4" in model or "gpt-3.5" in model:
            try:
                enc = tiktoken.encoding_for_model(model)
                return len(enc.encode(text))
            except:
                pass

        # Fallback: rough estimate (4 chars per token for CJK, 4 for EN)
        return len(text) // 4 + 1

    def count_message_tokens(self, messages: List[Dict[str, str]], model: str) -> int:
        total = 0
        for msg in messages:
            total += self.count_tokens(msg.get("content", ""), model)
            total += self.count_tokens(msg.get("role", ""), model)
        return total


class ModelRouter:
    """
    Main router implementing Race and Smart strategies.
    Zig layer calls into this via CFFI for cognitive delegation.
    """

    def __init__(self, config: RoutingConfig, providers: Dict[str, ModelProvider]):
        self.config = config
        self.providers = providers
        self.cost_tracker = CostTracker(config.budget_per_hour)
        self.token_counter = TokenCounter()
        self.session: Optional[aiohttp.ClientSession] = None
        self.stats: Dict[str, Any] = {
            "total_requests": 0,
            "race_wins": {},  # provider -> count
            "errors": {},
        }

    async def start(self):
        """Initialize HTTP session."""
        timeout = aiohttp.ClientTimeout(total=self.config.race_timeout_ms / 1000)
        self.session = aiohttp.ClientSession(timeout=timeout)

    async def stop(self):
        if self.session:
            await self.session.close()

    async def route(self, request: LLMRequest) -> LLMResponse:
        """
        Main entry point. Zig layer calls this via CFFI.
        Returns first successful response for race mode.
        """
        self.stats["total_requests"] += 1

        if self.config.strategy == RoutingStrategy.RACE:
            return await self._race(request)
        elif self.config.strategy == RoutingStrategy.SMART:
            return await self._smart_route(request)
        else:
            return await self._uniform_route(request)

    async def _race(self, request: LLMRequest) -> LLMResponse:
        """
        Race mode: Fire all candidates concurrently, return first success.
        If all fail, trigger fallback strategy.
        """
        start_time = time.time()

        # Create tasks for all candidates
        tasks = []
        for candidate in self.config.candidates:
            provider_id, model_id = candidate.split("/", 1)
            if provider_id not in self.providers:
                continue

            provider = self.providers[provider_id]
            req = LLMRequest(
                messages=request.messages,
                model=model_id,
                provider=provider_id,
                temperature=request.temperature,
                max_tokens=request.max_tokens,
            )
            task = asyncio.create_task(self._call_provider(provider, req))
            tasks.append((candidate, task))

        # Wait for first completion
        pending = [t[1] for t in tasks]
        done = []

        while pending:
            done, pending = await asyncio.wait(
                pending, 
                return_when=asyncio.FIRST_COMPLETED,
                timeout=self.config.race_timeout_ms / 1000
            )

            for task in done:
                try:
                    response = await task
                    if response.error is None:
                        # First successful response
                        provider_name = response.provider
                        self.stats["race_wins"][provider_name] =                             self.stats["race_wins"].get(provider_name, 0) + 1

                        # Cancel remaining tasks
                        for p in pending:
                            p.cancel()

                        return response
                except Exception as e:
                    continue

            if not pending:
                break

        # All candidates failed - trigger fallback
        if self.config.fallback_strategy:
            logger.warning("Race all failed, falling back to %s", self.config.fallback_strategy.value)
            # Create new request with fallback strategy
            fallback_config = RoutingConfig(
                strategy=self.config.fallback_strategy,
                fallback_strategy=None,
                budget_per_hour=self.config.budget_per_hour,
                candidates=self.config.candidates,
                weights=self.config.weights,
            )
            fallback_router = ModelRouter(fallback_config, self.providers)
            return await fallback_router.route(request)

        # Complete failure
        return LLMResponse(
            content="",
            provider="",
            model="",
            latency_ms=(time.time() - start_time) * 1000,
            tokens_in=0,
            tokens_out=0,
            cost_usd=0.0,
            finish_reason="error",
            error="All race candidates failed and no fallback configured",
        )

    async def _smart_route(self, request: LLMRequest) -> LLMResponse:
        """
        Smart routing: Weighted random selection based on quality/cost/latency.
        """
        # Calculate composite score for each provider
        scores = {}
        for provider_id, weight in self.config.weights.items():
            if provider_id not in self.providers:
                continue
            provider = self.providers[provider_id]

            # Score = weight * (1 - error_rate) / (1 + latency_ms/1000)
            latency_factor = 1.0 / (1.0 + provider.latency_ms / 1000.0)
            error_factor = 1.0 - provider.error_rate
            scores[provider_id] = weight * latency_factor * error_factor

        # Weighted random selection
        total_score = sum(scores.values())
        if total_score == 0:
            return await self._uniform_route(request)

        import random
        pick = random.uniform(0, total_score)
        current = 0
        selected = None
        for provider_id, score in scores.items():
            current += score
            if current >= pick:
                selected = provider_id
                break

        if selected is None:
            selected = list(scores.keys())[0]

        provider = self.providers[selected]
        req = LLMRequest(
            messages=request.messages,
            model=request.model,
            provider=selected,
            temperature=request.temperature,
            max_tokens=request.max_tokens,
        )

        return await self._call_provider(provider, req)

    async def _uniform_route(self, request: LLMRequest) -> LLMResponse:
        """Round-robin across candidates."""
        idx = self.stats["total_requests"] % len(self.config.candidates)
        candidate = self.config.candidates[idx]
        provider_id, model_id = candidate.split("/", 1)

        provider = self.providers[provider_id]
        req = LLMRequest(
            messages=request.messages,
            model=model_id,
            provider=provider_id,
            temperature=request.temperature,
            max_tokens=request.max_tokens,
        )

        return await self._call_provider(provider, req)

    async def _call_provider(self, provider: ModelProvider, request: LLMRequest) -> LLMResponse:
        """Execute HTTP request to provider with retries."""
        start_time = time.time()

        model_config = provider.get_model_config(request.model)
        if model_config is None:
            return LLMResponse(
                content="", provider=provider.id, model=request.model,
                latency_ms=0, tokens_in=0, tokens_out=0, cost_usd=0,
                finish_reason="error", error=f"Model {request.model} not found",
            )

        # Check budget
        est_cost = self._estimate_cost(request, model_config)
        if not await self.cost_tracker.charge(est_cost):
            return LLMResponse(
                content="", provider=provider.id, model=request.model,
                latency_ms=0, tokens_in=0, tokens_out=0, cost_usd=0,
                finish_reason="error", error="Hourly budget exceeded",
            )

        # Build request payload based on API compatibility
        payload = self._build_payload(provider.api_compat, request)

        headers = {
            "Authorization": f"Bearer {provider.api_key}",
            "Content-Type": "application/json",
        }

        # Execute with retries
        for attempt in range(self.config.retry_count + 1):
            try:
                async with self.session.post(
                    provider.endpoint + "/chat/completions",
                    headers=headers,
                    json=payload,
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        latency_ms = (time.time() - start_time) * 1000

                        # Update provider stats
                        provider.latency_ms = provider.latency_ms * 0.9 + latency_ms * 0.1

                        content = data["choices"][0]["message"]["content"]
                        tokens_in = data.get("usage", {}).get("prompt_tokens", 0)
                        tokens_out = data.get("usage", {}).get("completion_tokens", 0)

                        # Calculate actual cost
                        actual_cost = (
                            tokens_in * model_config["cost_in"] / 1_000_000 +
                            tokens_out * model_config["cost_out"] / 1_000_000
                        )

                        return LLMResponse(
                            content=content,
                            provider=provider.id,
                            model=request.model,
                            latency_ms=latency_ms,
                            tokens_in=tokens_in,
                            tokens_out=tokens_out,
                            cost_usd=actual_cost,
                            finish_reason=data["choices"][0].get("finish_reason", "stop"),
                        )

                    elif resp.status in (429, 500, 502, 503):
                        error_text = await resp.text()
                        if "rate_limit" in error_text.lower() and "rate_limit" in self.config.retry_on_errors:
                            if attempt < self.config.retry_count:
                                await asyncio.sleep(self.config.retry_delay_ms / 1000)
                                continue

                        return LLMResponse(
                            content="", provider=provider.id, model=request.model,
                            latency_ms=(time.time() - start_time) * 1000,
                            tokens_in=0, tokens_out=0, cost_usd=0,
                            finish_reason="error", error=f"HTTP {resp.status}: {error_text}",
                        )

                    else:
                        error_text = await resp.text()
                        return LLMResponse(
                            content="", provider=provider.id, model=request.model,
                            latency_ms=(time.time() - start_time) * 1000,
                            tokens_in=0, tokens_out=0, cost_usd=0,
                            finish_reason="error", error=f"HTTP {resp.status}: {error_text}",
                        )

            except asyncio.TimeoutError:
                if "timeout" in self.config.retry_on_errors and attempt < self.config.retry_count:
                    await asyncio.sleep(self.config.retry_delay_ms / 1000)
                    continue

                return LLMResponse(
                    content="", provider=provider.id, model=request.model,
                    latency_ms=(time.time() - start_time) * 1000,
                    tokens_in=0, tokens_out=0, cost_usd=0,
                    finish_reason="error", error="Request timeout",
                )

            except Exception as e:
                if "server_error" in self.config.retry_on_errors and attempt < self.config.retry_count:
                    await asyncio.sleep(self.config.retry_delay_ms / 1000)
                    continue

                return LLMResponse(
                    content="", provider=provider.id, model=request.model,
                    latency_ms=(time.time() - start_time) * 1000,
                    tokens_in=0, tokens_out=0, cost_usd=0,
                    finish_reason="error", error=str(e),
                )

        # Should not reach here
        return LLMResponse(
            content="", provider=provider.id, model=request.model,
            latency_ms=(time.time() - start_time) * 1000,
            tokens_in=0, tokens_out=0, cost_usd=0,
            finish_reason="error", error="Exhausted all retries",
        )

    def _build_payload(self, api_compat: str, request: LLMRequest) -> Dict[str, Any]:
        if api_compat == "openai":
            return {
                "model": request.model,
                "messages": request.messages,
                "temperature": request.temperature,
                "max_tokens": request.max_tokens,
                "stream": request.stream,
            }
        elif api_compat == "anthropic":
            return {
                "model": request.model,
                "messages": request.messages,
                "max_tokens": request.max_tokens or 4096,
                "temperature": request.temperature,
            }
        elif api_compat == "google":
            return {
                "contents": [{"role": m["role"], "parts": [{"text": m["content"]}]} 
                            for m in request.messages],
                "generationConfig": {
                    "temperature": request.temperature,
                    "maxOutputTokens": request.max_tokens,
                },
            }
        else:
            return {}

    def _estimate_cost(self, request: LLMRequest, model_config: Dict) -> float:
        tokens_in = self.token_counter.count_message_tokens(request.messages, request.model)
        # Assume output is half of input for estimation
        tokens_out = tokens_in // 2
        return (
            tokens_in * model_config["cost_in"] / 1_000_000 +
            tokens_out * model_config["cost_out"] / 1_000_000
        )

    def get_stats(self) -> Dict[str, Any]:
        return {
            **self.stats,
            "cost": self.cost_tracker.get_stats(),
            "provider_latencies": {k: v.latency_ms for k, v in self.providers.items()},
        }


# CFFI entry points for Zig layer to call into Python
async def init_router(config_json: str, providers_json: str) -> int:
    """Initialize router from JSON config. Returns handle."""
    config = RoutingConfig(**json.loads(config_json))
    providers = {k: ModelProvider(**v) for k, v in json.loads(providers_json).items()}

    router = ModelRouter(config, providers)
    await router.start()

    # Store in global registry (simplified)
    _router_registry[0] = router
    return 0

async def route_request(handle: int, request_json: str) -> str:
    """Route a request and return JSON response."""
    router = _router_registry.get(handle)
    if router is None:
        return json.dumps({"error": "Invalid router handle"})

    request = LLMRequest(**json.loads(request_json))
    response = await router.route(request)
    return json.dumps(response.__dict__)

_router_registry: Dict[int, ModelRouter] = {}


# ─── P2-2 FIX: CFFI Bridge Layer ───
# Boundary: Python = strategy selection only, Zig = HTTP execution
# _call_provider is marked for migration to Zig (io_uring HTTP client)

# CFFI entry point: Zig calls Python for strategy, Python returns decision
# Zig then executes HTTP via io_uring and returns result back to Python
async def select_provider(config_json: str, context_json: str) -> str:
    """P2-2 FIX: Strategy-only entry point. Returns provider selection, not HTTP response."""
    config = RoutingConfig(**json.loads(config_json))
    context = json.loads(context_json)
    # Pure strategy: pick provider based on config weights/cost/latency
    model_router = ModelRouter(config, {})
    selected = None
    if config.strategy == RoutingStrategy.RACE:
        selected = config.candidates[0] if config.candidates else None
    elif config.strategy == RoutingStrategy.SMART and config.weights:
        total_w = sum(config.weights.values())
        if total_w > 0:
            import random
            pick = random.uniform(0, total_w)
            cur = 0
            for pid, w in config.weights.items():
                cur += w
                if cur >= pick:
                    selected = pid
                    break
        selected = selected or (list(config.weights.keys())[0] if config.weights else None)
    elif config.candidates:
        idx = int(context.get("request_count", 0)) % len(config.candidates)
        selected = config.candidates[idx]
    return json.dumps({"provider": selected or "", "strategy": config.strategy.value})


if __name__ == "__main__":
    print("LingNet Router Core V2.5 - Python Layer initialized (thin strategy + CFFI bridge)")

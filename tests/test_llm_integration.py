#!/usr/bin/env python3
"""
LingNet Agent OS V2.5 — LLM API Integration Test (P0-3)
Tests real HTTP calls to LLM providers using aiohttp + mock server.
Run: python3 test_llm_integration.py
"""

import asyncio
import json
import time
import sys
from unittest.mock import AsyncMock, patch, MagicMock

# Import the router core
from python_router_core import (
    ModelRouter, ModelProvider, RoutingConfig,
    RoutingStrategy, LLMRequest, LLMResponse,
)


async def test_mock_openai_call():
    """Test: _call_provider with mocked OpenAI response."""
    config = RoutingConfig(
        strategy=RoutingStrategy.RACE,
        fallback_strategy=None,
        budget_per_hour=10.0,
        candidates=["openai/gpt-4o"],
        weights={"openai": 1},
        retry_count=1,
        race_timeout_ms=5000,
    )
    provider = ModelProvider(
        id="openai",
        name="OpenAI",
        endpoint="https://api.openai.com/v1",
        api_key="sk-test-key",
        api_compat="openai",
        models=[{"id": "gpt-4o", "cost_in": 2.5, "cost_out": 10.0}],
    )
    router = ModelRouter(config, {"openai": provider})
    await router.start()

    # Mock the HTTP response
    mock_response = MagicMock()
    mock_response.status = 200
    mock_response.json = AsyncMock(return_value={
        "choices": [{"message": {"content": "Hello from test"}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5},
    })
    mock_response.__aenter__ = AsyncMock(return_value=mock_response)
    mock_response.__aexit__ = AsyncMock(return_value=None)

    with patch.object(router.session, 'post', return_value=mock_response):
        request = LLMRequest(
            messages=[{"role": "user", "content": "Hello"}],
            model="gpt-4o",
            provider="openai",
        )
        response = await router._call_provider(provider, request)

    assert response.error is None, f"Expected no error, got: {response.error}"
    assert response.content == "Hello from test"
    assert response.tokens_in == 10
    assert response.tokens_out == 5
    assert response.cost_usd > 0
    print("  ✅ test_mock_openai_call PASSED")


async def test_mock_rate_limit_retry():
    """Test: Rate limit (429) triggers retry."""
    config = RoutingConfig(
        strategy=RoutingStrategy.RACE,
        fallback_strategy=None,
        budget_per_hour=10.0,
        candidates=["openai/gpt-4o"],
        weights={},
        retry_count=2,
        retry_delay_ms=10,
        race_timeout_ms=5000,
    )
    provider = ModelProvider(
        id="openai", name="OpenAI",
        endpoint="https://api.openai.com/v1",
        api_key="sk-test", api_compat="openai",
        models=[{"id": "gpt-4o", "cost_in": 2.5, "cost_out": 10.0}],
    )
    router = ModelRouter(config, {"openai": provider})
    await router.start()

    # First call returns 429, second returns 200
    error_response = MagicMock()
    error_response.status = 429
    error_response.text = AsyncMock(return_value="rate_limit_exceeded")

    ok_response = MagicMock()
    ok_response.status = 200
    ok_response.json = AsyncMock(return_value={
        "choices": [{"message": {"content": "Retry OK"}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 5, "completion_tokens": 3},
    })
    error_response.__aenter__ = AsyncMock(return_value=error_response)
    error_response.__aexit__ = AsyncMock(return_value=None)
    ok_response.__aenter__ = AsyncMock(return_value=ok_response)
    ok_response.__aexit__ = AsyncMock(return_value=None)

    call_count = 0
    async def mock_post(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return error_response if call_count == 1 else ok_response

    with patch.object(router.session, 'post', side_effect=mock_post):
        request = LLMRequest(
            messages=[{"role": "user", "content": "Hello"}],
            model="gpt-4o", provider="openai",
        )
        response = await router._call_provider(provider, request)

    assert response.error is None, f"Expected retry success, got: {response.error}"
    assert response.content == "Retry OK"
    assert call_count == 2, f"Expected 2 calls, got {call_count}"
    print("  ✅ test_mock_rate_limit_retry PASSED")


async def test_budget_exceeded():
    """Test: Budget enforcement blocks expensive requests."""
    config = RoutingConfig(
        strategy=RoutingStrategy.RACE,
        fallback_strategy=None,
        budget_per_hour=0.001,  # Very small budget
        candidates=["openai/gpt-4o"],
        weights={},
        retry_count=0,
        race_timeout_ms=5000,
    )
    provider = ModelProvider(
        id="openai", name="OpenAI",
        endpoint="https://api.openai.com/v1",
        api_key="sk-test", api_compat="openai",
        models=[{"id": "gpt-4o", "cost_in": 2.5, "cost_out": 10.0}],
    )
    router = ModelRouter(config, {"openai": provider})
    await router.start()

    request = LLMRequest(
        messages=[{"role": "user", "content": "x" * 1000}],  # Large input = high cost
        model="gpt-4o", provider="openai",
    )
    response = await router._call_provider(provider, request)

    assert response.error is not None
    assert "budget" in response.error.lower()
    print("  ✅ test_budget_exceeded PASSED")


async def test_timeout_retry():
    """Test: Timeout triggers retry."""
    config = RoutingConfig(
        strategy=RoutingStrategy.RACE,
        fallback_strategy=None,
        budget_per_hour=10.0,
        candidates=["openai/gpt-4o"],
        weights={},
        retry_count=2,
        retry_on_errors=["timeout"],
        race_timeout_ms=5000,
    )
    provider = ModelProvider(
        id="openai", name="OpenAI",
        endpoint="https://api.openai.com/v1",
        api_key="sk-test", api_compat="openai",
        models=[{"id": "gpt-4o", "cost_in": 2.5, "cost_out": 10.0}],
    )
    router = ModelRouter(config, {"openai": provider})
    await router.start()

    call_count = 0
    async def mock_timeout(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        if call_count <= 1:
            raise asyncio.TimeoutError()
        # Second call succeeds
        ok = MagicMock()
        ok.status = 200
        ok.json = AsyncMock(return_value={
            "choices": [{"message": {"content": "After timeout"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 3},
        })
        ok.__aenter__ = AsyncMock(return_value=ok)
        ok.__aexit__ = AsyncMock(return_value=None)
        return ok

    with patch.object(router.session, 'post', side_effect=mock_timeout):
        request = LLMRequest(
            messages=[{"role": "user", "content": "Hello"}],
            model="gpt-4o", provider="openai",
        )
        response = await router._call_provider(provider, request)

    assert response.error is None, f"Expected retry success, got: {response.error}"
    assert response.content == "After timeout"
    print("  ✅ test_timeout_retry PASSED")


async def main():
    print("=== P0-3: LLM API Integration Tests ===")
    start = time.time()

    await test_mock_openai_call()
    await test_mock_rate_limit_retry()
    await test_budget_exceeded()
    await test_timeout_retry()

    elapsed = time.time() - start
    print(f"\n✅ All P0-3 integration tests passed ({elapsed:.2f}s)")


if __name__ == "__main__":
    asyncio.run(main())

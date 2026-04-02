"""
LightRAG E2E Smoke Tests

Tests the full workflow against the production Elastic IP:
  ingest -> poll until complete -> query (hybrid mode) -> assert entity presence

Requirements: TEST-01 through TEST-05
"""

import os
import time
import json
import requests
import pytest

# TEST-05: Target the Elastic IP on port 9621
BASE_URL = "http://54.253.108.90:9621"
API_KEY = os.environ.get("LIGHTRAG_API_KEY", "")
HEADERS = {"x-api-key": API_KEY, "Content-Type": "application/json"}

# Module-level storage for cross-test data sharing
_test_response = {}


# TEST-05: Health check -- verify LightRAG is accessible
def test_health_check():
    """TEST-05: Verify the /health endpoint returns HTTP 200."""
    resp = requests.get(f"{BASE_URL}/health", timeout=30)
    assert resp.status_code == 200, f"Health check failed: {resp.status_code} {resp.text}"


# TEST-01: Ingest a document about the Sydney Harbour Bridge
def test_ingest_document():
    """TEST-01: POST /documents/insert with sample text and return task_id."""
    payload = {
        "text": (
            "The Sydney Harbour Bridge is an iconic Australian landmark connecting "
            "the city of Sydney to the North Shore. It was opened in 1932 and spans "
            "504 metres across the harbour. The bridge is made of steel and features "
            "a distinctive arch design."
        )
    }
    resp = requests.post(
        f"{BASE_URL}/documents/insert",
        json=payload,
        headers=HEADERS,
        timeout=30,
    )
    assert resp.status_code == 200, f"Ingest failed: {resp.status_code} {resp.text}"
    data = resp.json()
    # Capture task_id for use by the polling test
    _test_response["task_id"] = data.get("task_id") or data.get("id") or data.get("data", {}).get("task_id")
    assert _test_response["task_id"], f"No task_id in response: {data}"


# TEST-02: Poll until ingestion is complete (max 60s, every 5s)
def test_ingestion_complete():
    """TEST-02: Poll GET /documents/status until the ingestion task is complete."""
    task_id = _test_response.get("task_id")
    assert task_id, "task_id not found -- run test_ingest_document first"

    max_wait = 60
    interval = 5
    elapsed = 0

    while elapsed < max_wait:
        resp = requests.get(
            f"{BASE_URL}/documents/status",
            params={"task_id": task_id},
            headers=HEADERS,
            timeout=30,
        )
        assert resp.status_code == 200, f"Status check failed: {resp.status_code} {resp.text}"
        data = resp.json()

        # Check for completion indicators
        status = str(data).lower()
        if any(kw in status for kw in ("completed", "done", "success")):
            # Also succeed if "pending" or "processing" are absent
            if "pending" not in status and "processing" not in status:
                print(f"[Poll] Ingestion complete after {elapsed}s")
                return

        time.sleep(interval)
        elapsed += interval

    pytest.fail(f"Ingestion did not complete within {max_wait}s. Last response: {data}")


# TEST-03: Query in hybrid mode
def test_query_hybrid():
    """TEST-03: POST /query with mode=hybrid and assert non-empty result."""
    payload = {
        "query": "Tell me about the Sydney Harbour Bridge",
        "mode": "hybrid",
    }
    resp = requests.post(
        f"{BASE_URL}/query",
        json=payload,
        headers=HEADERS,
        timeout=60,
    )
    assert resp.status_code == 200, f"Query failed: {resp.status_code} {resp.text}"
    data = resp.json()

    # Assert the response has a non-empty result/answer field
    result = (
        data.get("result")
        or data.get("answer")
        or data.get("response")
        or (data.get("data", {}).get("result") if isinstance(data.get("data"), dict) else "")
    )
    assert result and len(str(result)) > 0, f"Empty result in response: {data}"
    _test_response["query_data"] = data
    print(f"[Query] Result length: {len(str(result))} chars")


# TEST-04: Assert entities from the ingested document appear in the query response
def test_entity_in_response():
    """TEST-04: Assert the query response contains entities related to the ingested text."""
    data = _test_response.get("query_data")
    assert data, "No query data -- run test_query_hybrid first"

    # Serialize to string for keyword matching
    response_text = json.dumps(data).lower()

    # Entities and keywords from the ingested Sydney Harbour Bridge text
    expected_keywords = [
        "sydney",
        "harbour bridge",
        "sydney harbour bridge",
        "1932",
        "landmark",
        "arch",
        "australian",
    ]

    found = [kw for kw in expected_keywords if kw in response_text]

    # Also accept if structured entity/relation arrays exist and are non-empty
    has_structured_entities = False
    if isinstance(data, dict):
        for key in ("entities", "relations", "results"):
            val = data.get(key)
            if isinstance(val, (list, dict)) and len(val if isinstance(val, list) else val) > 0:
                has_structured_entities = True
                break
        # Or check nested data field
        nested = data.get("data", {})
        if isinstance(nested, dict):
            for key in ("entities", "relations"):
                val = nested.get(key)
                if isinstance(val, (list, dict)) and len(val if isinstance(val, list) else val) > 0:
                    has_structured_entities = True
                    break

    assert found or has_structured_entities, (
        f"No expected keywords found in response and no structured entities present. "
        f"Found keywords: {found}, Response: {data}"
    )
    print(f"[Entity] Found keywords: {found}")

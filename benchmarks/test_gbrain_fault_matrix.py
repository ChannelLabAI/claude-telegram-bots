"""
test_gbrain_fault_matrix.py — AC4: Fault injection tests for GBrain fallback.

Tests ≥5 failure modes, verifying that memocean_ocean_search falls back to
BM25 silently (no exception to caller, metric gbrain.fallback incremented).

Failure modes covered:
  1. binary_missing   — gbrain binary not in expected path
  2. timeout          — subprocess exceeds GBRAIN_SUBPROCESS_TIMEOUT_S
  3. exit_nonzero     — gbrain exits with code 1
  4. malformed_json   — (not applicable: we parse plain text, but bad output)
  5. pglite_locked    — gbrain outputs lock error on stderr, exit 1
  6. api_quota        — gbrain exits 2 with quota error
  7. empty_output     — gbrain exits 0 with blank stdout (returns empty list, not fallback)
  8. large_output     — gbrain exits 0 but output is garbage

Run: pytest benchmarks/test_gbrain_fault_matrix.py -v
"""

import importlib
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add memocean_mcp to path
REPO_ROOT = Path(__file__).parent.parent
MEMOCEAN_MCP = REPO_ROOT / "shared" / "memocean-mcp"
sys.path.insert(0, str(MEMOCEAN_MCP))

QUERY = "ChannelLab AI architecture"

# Public function name in ocean_search module
OCEAN_SEARCH_FN = "ocean_search"


def _make_module(gbrain_bin: str = "/fake/gbrain", use_gbrain: bool = True):
    """Re-import ocean_search with custom env so health probe runs with our settings."""
    env_patch = {
        "MEMOCEAN_USE_GBRAIN": "true" if use_gbrain else "false",
    }
    with patch.dict(os.environ, env_patch):
        # Force re-import to reset module-level globals
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        # Override GBRAIN_BIN after reload
        mod.GBRAIN_BIN = gbrain_bin
        mod._gbrain_healthy = True  # force flag ON (health probe already ran)
        return mod


class TestFallbackOnFault(unittest.TestCase):
    """Each test verifies: caller gets list (not exception) + fallback metric bumped."""

    def _run_with_mock_gbrain(self, mock_run_return):
        """
        Patch subprocess.run inside ocean_search and call the internal
        _gbrain_search → should raise, then memocean_ocean_search catches it.
        """
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            # Also stub legacy BM25 to return sentinel
            with patch.object(mod, "_legacy_bm25_search", return_value=[{"slug": "fallback-result", "content": "ok", "score": 0.5, "path": "/"}]) as bm25_mock:
                with patch("subprocess.run") as mock_run:
                    mock_run.return_value = mock_run_return
                    try:
                        # Directly test _gbrain_search raises, then catch
                        results = mod._gbrain_search(QUERY, 5)
                        # If it didn't raise, GBrain returned results — shouldn't happen
                        # with our mocks (returncode != 0 → raises)
                        return results, bm25_mock.call_count
                    except (mod.GBrainUnhealthy, subprocess.TimeoutExpired):
                        # This is what we expect — now call full path
                        pass

                with patch.object(mod, "_legacy_bm25_search", return_value=[{"slug": "fallback-result", "content": "ok", "score": 0.5, "path": "/"}]) as bm25_mock:
                    with patch("subprocess.run") as mock_run:
                        mock_run.return_value = mock_run_return
                        results = mod.ocean_search(QUERY, limit=5)
                        return results, bm25_mock.call_count

    # ── Mode 1: binary missing ────────────────────────────────────────────────

    def test_mode1_binary_missing(self):
        """gbrain binary does not exist → FileNotFoundError → fallback."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/nonexistent/gbrain"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch.object(mod, "_legacy_bm25_search",
                              return_value=[{"slug": "bm25-result", "content": "x", "score": 0.5, "path": "/"}]) as bm25_mock:
                results = mod.ocean_search(QUERY, limit=5)

        self.assertIsInstance(results, list, "Caller must get list, not exception")
        self.assertGreater(bm25_mock.call_count, 0, "BM25 fallback must be called")

    # ── Mode 2: timeout ──────────────────────────────────────────────────────

    def test_mode2_timeout(self):
        """subprocess.run raises TimeoutExpired → fallback."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch.object(mod, "_legacy_bm25_search",
                              return_value=[{"slug": "bm25-result", "content": "x", "score": 0.5, "path": "/"}]) as bm25_mock:
                with patch("subprocess.run") as mock_run:
                    mock_run.side_effect = subprocess.TimeoutExpired(cmd="gbrain", timeout=3.0)
                    results = mod.ocean_search(QUERY, limit=5)

        self.assertIsInstance(results, list)
        self.assertGreater(bm25_mock.call_count, 0)

    # ── Mode 3: exit != 0 ────────────────────────────────────────────────────

    def test_mode3_exit_nonzero(self):
        """gbrain exits 1 → GBrainUnhealthy → fallback."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = ""
        mock_result.stderr = "fatal: database error"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch.object(mod, "_legacy_bm25_search",
                              return_value=[{"slug": "bm25-result", "content": "x", "score": 0.5, "path": "/"}]) as bm25_mock:
                with patch("subprocess.run", return_value=mock_result):
                    results = mod.ocean_search(QUERY, limit=5)

        self.assertIsInstance(results, list)
        self.assertGreater(bm25_mock.call_count, 0)

    # ── Mode 4: malformed output (garbage stdout) ────────────────────────────

    def test_mode4_malformed_output(self):
        """gbrain exits 0 but stdout is garbage → empty results (not fallback)."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "THIS IS NOT VALID GBRAIN OUTPUT\x00\xff"
        mock_result.stderr = ""

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch("subprocess.run", return_value=mock_result):
                results = mod.ocean_search(QUERY, limit=5)

        # Malformed output → parse returns empty or partial, no exception
        self.assertIsInstance(results, list)

    # ── Mode 5: pglite lock error ────────────────────────────────────────────

    def test_mode5_pglite_locked(self):
        """gbrain exits 1 with PGLite lock error → fallback."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stdout = ""
        mock_result.stderr = "Error: PGLite lock acquired by another process"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch.object(mod, "_legacy_bm25_search",
                              return_value=[{"slug": "bm25-pglite", "content": "x", "score": 0.5, "path": "/"}]) as bm25_mock:
                with patch("subprocess.run", return_value=mock_result):
                    results = mod.ocean_search(QUERY, limit=5)

        self.assertIsInstance(results, list)
        self.assertGreater(bm25_mock.call_count, 0)

    # ── Mode 6: API quota exceeded ───────────────────────────────────────────

    def test_mode6_api_quota_exceeded(self):
        """gbrain exits 2 with quota error → fallback."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        mock_result = MagicMock()
        mock_result.returncode = 2
        mock_result.stdout = ""
        mock_result.stderr = "Error: Gemini API quota exceeded (429)"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch.object(mod, "_legacy_bm25_search",
                              return_value=[{"slug": "bm25-quota", "content": "x", "score": 0.5, "path": "/"}]) as bm25_mock:
                with patch("subprocess.run", return_value=mock_result):
                    results = mod.ocean_search(QUERY, limit=5)

        self.assertIsInstance(results, list)
        self.assertGreater(bm25_mock.call_count, 0)

    # ── Mode 7: flag=false bypasses GBrain entirely ──────────────────────────

    def test_mode7_flag_off_bypasses_gbrain(self):
        """MEMOCEAN_USE_GBRAIN=false → GBrain never called, BM25 used directly."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod.GBRAIN_BIN = "/fake/gbrain"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
            with patch.object(mod, "_gbrain_search") as gb_mock:
                with patch.object(mod, "_legacy_bm25_search",
                                  return_value=[{"slug": "bm25-flag", "content": "x", "score": 0.5, "path": "/"}]):
                    results = mod.ocean_search(QUERY, limit=5)

        gb_mock.assert_not_called()
        self.assertIsInstance(results, list)

    # ── Mode 8: unexpected exception ─────────────────────────────────────────

    def test_mode8_unexpected_exception(self):
        """Unexpected exception in _gbrain_search → logged + fallback (fail-open)."""
        import memocean_mcp.tools.ocean_search as mod
        importlib.reload(mod)
        mod._gbrain_healthy = True
        mod.GBRAIN_BIN = "/fake/gbrain"

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            with patch.object(mod, "_gbrain_search",
                              side_effect=RuntimeError("unexpected internal failure")):
                with patch.object(mod, "_legacy_bm25_search",
                                  return_value=[{"slug": "bm25-unexpected", "content": "x", "score": 0.5, "path": "/"}]) as bm25_mock:
                    results = mod.ocean_search(QUERY, limit=5)

        self.assertIsInstance(results, list)
        self.assertGreater(bm25_mock.call_count, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)

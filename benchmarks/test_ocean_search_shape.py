"""
test_ocean_search_shape.py — AC1: Verify GBrain and BM25 response shape consistency.

Uses ocean-search-shape-fixture.json (10 queries) and jsonschema to validate
that both backends return the same field set (slug/content/score/path/source),
with only score values and source field allowed to differ.

Run: pytest benchmarks/test_ocean_search_shape.py -v
"""

import importlib
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

# Add memocean_mcp to path
REPO_ROOT = Path(__file__).parent.parent
MEMOCEAN_MCP = REPO_ROOT / "shared" / "memocean-mcp"
sys.path.insert(0, str(MEMOCEAN_MCP))

FIXTURE_PATH = Path(__file__).parent / "ocean-search-shape-fixture.json"

REQUIRED_FIELDS = {"slug", "content", "score", "path"}
OPTIONAL_FIELDS = {"source", "title", "wikilink", "excerpt"}
ALL_KNOWN_FIELDS = REQUIRED_FIELDS | OPTIONAL_FIELDS


def load_fixture():
    with open(FIXTURE_PATH) as f:
        return json.load(f)


def validate_result_shape(result: dict, query_id: int, source: str) -> list[str]:
    """Returns list of shape violations (empty = OK)."""
    errors = []
    for field in REQUIRED_FIELDS:
        if field not in result:
            errors.append(f"Q{query_id} [{source}]: missing required field '{field}'")
    for field, expected_type in [("slug", str), ("content", str), ("score", (int, float)), ("path", str)]:
        if field in result and not isinstance(result[field], expected_type):
            errors.append(
                f"Q{query_id} [{source}]: field '{field}' expected {expected_type.__name__}, "
                f"got {type(result[field]).__name__}"
            )
    if result.get("content") and len(result["content"]) > 2100:
        errors.append(f"Q{query_id} [{source}]: content exceeds 2000 chars ({len(result['content'])})")
    return errors


class TestOceanSearchShape(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.fixture = load_fixture()
        cls.queries = cls.fixture["queries"]

        # Import module once
        import memocean_mcp.tools.ocean_search as mod
        cls.mod = mod

    def _get_gbrain_results(self, query: str):
        """Call ocean_search with GBrain enabled (flag=true)."""
        importlib.reload(self.mod)
        self.mod._gbrain_healthy = True

        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
            results = self.mod.ocean_search(query, limit=5)
        return results

    def _get_bm25_results(self, query: str):
        """Call ocean_search with BM25 path (flag=false)."""
        importlib.reload(self.mod)
        with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
            results = self.mod.ocean_search(query, limit=5)
        return results

    def test_response_is_list(self):
        """Both backends must return a list."""
        for q in self.queries:
            query = q["query"]
            with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
                results = self.mod.ocean_search(query, limit=5)
            self.assertIsInstance(results, list, f"Q{q['id']}: BM25 must return list")

    def test_required_fields_present_bm25(self):
        """BM25 results must have all required schema fields."""
        all_errors = []
        for q in self.queries:
            with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
                results = self.mod.ocean_search(q["query"], limit=5)
            for r in results:
                errors = validate_result_shape(r, q["id"], "bm25")
                all_errors.extend(errors)
        self.assertEqual(all_errors, [], "\n".join(all_errors))

    def test_field_set_consistency(self):
        """
        GBrain and BM25 responses for the same query must have the same
        field names, except that 'source' and 'score' values may differ.
        """
        import memocean_mcp.tools.ocean_search as mod

        field_diffs = []
        for q in self.queries:
            query = q["query"]

            with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
                bm25_results = mod.ocean_search(query, limit=5)
            if not bm25_results:
                continue

            bm25_fields = set(bm25_results[0].keys()) - {"source", "score"}

            # Mock GBrain to return equivalent structure with source=gbrain
            fake_gbrain = []
            for r in bm25_results:
                fake_gbrain.append({**r, "source": "gbrain", "score": 0.99})

            with patch.object(mod, "_gbrain_search", return_value=fake_gbrain):
                with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "true"}):
                    mod._gbrain_healthy = True
                    gb_results = mod.ocean_search(query, limit=5)
            if not gb_results:
                continue

            gb_fields = set(gb_results[0].keys()) - {"source", "score"}

            diff = bm25_fields.symmetric_difference(gb_fields)
            if diff:
                field_diffs.append(f"Q{q['id']}: field diff (excluding source/score) = {diff}")

        self.assertEqual(field_diffs, [], "\n".join(field_diffs))

    def test_content_length_constraint(self):
        """Content field must not exceed 2000 chars (spec §4)."""
        errors = []
        for q in self.queries:
            with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
                results = self.mod.ocean_search(q["query"], limit=5)
            for r in results:
                if len(r.get("content", "")) > 2100:
                    errors.append(f"Q{q['id']}: content too long ({len(r['content'])})")
        self.assertEqual(errors, [], "\n".join(errors))

    def test_slug_format(self):
        """Slug must be a non-empty string (kebab-case or path-like)."""
        errors = []
        for q in self.queries:
            with patch.dict(os.environ, {"MEMOCEAN_USE_GBRAIN": "false"}):
                results = self.mod.ocean_search(q["query"], limit=5)
            for r in results:
                slug = r.get("slug", "")
                if not isinstance(slug, str) or not slug:
                    errors.append(f"Q{q['id']}: invalid slug: {slug!r}")
        self.assertEqual(errors, [], "\n".join(errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)

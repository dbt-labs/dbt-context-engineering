#!/usr/bin/env python3
"""Regression tests for the macro call-graph walk. Plain asserts, no test framework, so CI can
run this with nothing installed:

    python ci/test_macro_call_graph.py

The case that matters is the bare adapter.dispatch edge. chunk.sql reaches array_agg and
string_agg that way, so the package-qualified convention ADR-0025 describes is not universal, and
a walk that followed only qualified calls would leave a helper in embed()'s closure outside the
hashed file set. If someone narrows the walk to qualified calls only, the first assertion here
goes red.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from macro_call_graph import MACROS_DIR, called_macro_names, walk_call_graph  # noqa: E402


def _rel(paths: list[Path]) -> set[str]:
    return {str(p.relative_to(MACROS_DIR)) for p in paths}


def test_bare_dispatch_edges_are_followed() -> None:
    chunk = MACROS_DIR / "chunking" / "chunk.sql"
    names = called_macro_names(chunk.read_text())
    assert "array_agg" in names, "bare adapter.dispatch('array_agg') edge not seen"
    assert "string_agg" in names, "bare adapter.dispatch('string_agg') edge not seen"

    closure = _rel(walk_call_graph([chunk]))
    assert "chunking/helpers/array_agg.sql" in closure, closure
    assert "chunking/helpers/string_agg.sql" in closure, closure


def test_qualified_call_edges_are_followed() -> None:
    chunk = MACROS_DIR / "chunking" / "chunk.sql"
    names = called_macro_names(chunk.read_text())
    assert {"content_hash", "chunk_fn_fingerprint", "row_value_not_in"} <= names, names


def test_dispatch_variants_resolve_to_their_defining_file() -> None:
    """A dispatched name is followed to every file defining the bare name or a <prefix>__<name>
    variant, because the walk cannot know which adapter will be selected at run time."""
    closure = _rel(walk_call_graph([MACROS_DIR / "retrieval" / "vector_search.sql"]))
    assert "retrieval/vector_search.sql" in closure, closure


def test_embed_closure_is_the_hashed_file_set() -> None:
    """The set embedding_logic_hash() is computed over. Listed explicitly so widening it is a
    deliberate edit here, not a silent side effect of an unrelated refactor."""
    closure = _rel(walk_call_graph([MACROS_DIR / "functions" / "embed.sql"]))
    assert closure == {"functions/embed.sql", "functions/require_prerequisites.sql"}, closure


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"{len(tests)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

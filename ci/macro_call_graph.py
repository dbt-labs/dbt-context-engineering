#!/usr/bin/env python3
"""Walk this package's macro call graph from a set of entry files.

dbt-core's own MacroParser does not track macro-to-macro dependencies in the manifest, so a
regex walk is the actual mechanism available, not a workaround for a better one.

ci/verify_embedding_logic_hash.py is its caller. The walk is a separate module so anything else
that needs the graph can import it without pulling in that gate's hashing and file writing.

Two kinds of edge are followed.

1. A package-qualified call, `dbt_context_engineering.<name>(...)`. The README states this is the
   convention, and it is how almost every call in the package is written.

2. A bare `adapter.dispatch('<name>', 'dbt_context_engineering')`. macros/chunking/chunk.sql
   reaches array_agg and string_agg this way, so the convention in (1) is not universal and a walk
   that followed only qualified calls would miss those edges. That matters for the
   embedding_logic_hash gate in particular: a helper reached from embed()'s closure by bare
   dispatch would sit outside the hashed file set, leaving the gate green while embed()'s real
   logic changed.

A dispatched name resolves at run time to `<adapter>__<name>` or `default__<name>`, and which one
is chosen depends on the target. The walk cannot know the target, so it follows the edge to every
file defining the bare name or any `<prefix>__<name>` variant. Over-inclusion is the safe
direction here: a hash that covers a file it did not strictly need is a spurious regeneration,
while a missed file is a gate that passes on changed logic.

Still invisible to this: a macro name assembled at run time from a variable. See ADR-0025's
Consequences section.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MACROS_DIR = REPO_ROOT / "macros"

PACKAGE_NAME = "dbt_context_engineering"

QUALIFIED_CALL_PATTERN = re.compile(rf"{PACKAGE_NAME}\.(\w+)\s*\(")
DISPATCH_CALL_PATTERN = re.compile(
    r"""adapter\.dispatch\(\s*['"](\w+)['"]"""
)


def _macro_def_pattern(macro_name: str) -> re.Pattern:
    """Matches a definition of `macro_name` itself, or of any dispatch variant of it
    (`default__<name>`, `snowflake__<name>`, and so on)."""
    return re.compile(
        r"\{%-?\s*(?:macro|test)\s+(?:\w+__)?" + re.escape(macro_name) + r"\s*\("
    )


def _find_defining_files(macro_name: str, all_sql_files: list[Path]) -> list[Path]:
    pattern = _macro_def_pattern(macro_name)
    return [f for f in all_sql_files if pattern.search(f.read_text())]


def called_macro_names(source: str) -> set[str]:
    """Every macro name reached from `source`, by either edge kind."""
    return set(QUALIFIED_CALL_PATTERN.findall(source)) | set(
        DISPATCH_CALL_PATTERN.findall(source)
    )


def walk_call_graph(entry_files: list[Path]) -> list[Path]:
    """Fixed-point closure over the call graph. Returns a sorted, deduped file list."""
    all_sql_files = sorted(MACROS_DIR.rglob("*.sql"))
    visited: set[Path] = set()
    queue = list(entry_files)

    while queue:
        current = queue.pop()
        if current in visited:
            continue
        visited.add(current)

        for macro_name in called_macro_names(current.read_text()):
            for defining_file in _find_defining_files(macro_name, all_sql_files):
                if defining_file not in visited:
                    queue.append(defining_file)

    return sorted(visited)

#!/usr/bin/env python3
"""Verify or generate embedding_logic_hash()'s content hash.

embedding_logic_hash() identifies the embedding-relevant source in this package for audit
purposes, never for gating reprocessing (see ADR-0025). The file set is derived by walking
embed()'s call graph, a regex over `dbt_context_engineering.<name>(...)` calls starting from
macros/functions/embed.sql, recursively, rather than hand-listed, so a newly-relevant file is
picked up automatically the next time this script runs.

This only detects literal, package-qualified macro calls, the one convention this codebase uses
everywhere today. dbt-core's own MacroParser does not track macro-to-macro dependencies in the
manifest, so this regex walk is the actual mechanism, not a workaround for a better one. A
dynamically-constructed macro name is invisible to it; see ADR-0025's Consequences section.

Usage:
    python ci/verify_embedding_logic_hash.py            # check mode (default), exits 1 if stale
    python ci/verify_embedding_logic_hash.py --generate  # recompute and rewrite the checked-in literal
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MACROS_DIR = REPO_ROOT / "macros"
ENTRY_FILES = [MACROS_DIR / "functions" / "embed.sql"]
GENERATED_MACRO_PATH = MACROS_DIR / "embedding" / "embedding_logic_hash.sql"

CALL_PATTERN = re.compile(r"dbt_context_engineering\.(\w+)\s*\(")
HASH_LITERAL_PATTERN = re.compile(r"return\(\s*'([0-9a-f]{64})'\s*\)")


def _macro_def_pattern(macro_name: str) -> re.Pattern:
    return re.compile(r"\{%-?\s*macro\s+" + re.escape(macro_name) + r"\s*\(")


def _find_defining_file(macro_name: str, all_sql_files: list[Path]) -> Path | None:
    pattern = _macro_def_pattern(macro_name)
    for f in all_sql_files:
        if pattern.search(f.read_text()):
            return f
    return None


def walk_call_graph(entry_files: list[Path]) -> list[Path]:
    """Fixed-point closure over embed()'s call graph. Returns a sorted, deduped file list."""
    all_sql_files = list(MACROS_DIR.rglob("*.sql"))
    visited: set[Path] = set()
    queue = list(entry_files)

    while queue:
        current = queue.pop()
        if current in visited:
            continue
        visited.add(current)

        for match in CALL_PATTERN.finditer(current.read_text()):
            macro_name = match.group(1)
            defining_file = _find_defining_file(macro_name, all_sql_files)
            if defining_file is not None and defining_file not in visited:
                queue.append(defining_file)

    return sorted(visited)


def compute_hash(files: list[Path]) -> str:
    """Content hash over relative path + bytes for every file in the closure, order-independent
    (files are pre-sorted by walk_call_graph) so renaming a file without changing its content
    still changes the hash. That is intended: a rename is a real change to the artifact."""
    digest = hashlib.sha256()
    for f in files:
        digest.update(str(f.relative_to(REPO_ROOT)).encode("utf-8"))
        digest.update(f.read_bytes())
    return digest.hexdigest()


def read_checked_in_hash() -> str | None:
    if not GENERATED_MACRO_PATH.exists():
        return None
    match = HASH_LITERAL_PATTERN.search(GENERATED_MACRO_PATH.read_text())
    return match.group(1) if match else None


def write_macro(hash_value: str, files: list[Path]) -> None:
    file_list = "\n".join(f"    - {f.relative_to(REPO_ROOT)}" for f in files)
    content = (
        "{#-\n"
        "  embedding_logic_hash() -> a content hash of the embedding-relevant source in this\n"
        "  package. GENERATED, do not hand-edit. Regenerate with:\n"
        "    python ci/verify_embedding_logic_hash.py --generate\n"
        "\n"
        "  File set, derived by walking embed()'s call graph, not hand-listed. See\n"
        "  ci/verify_embedding_logic_hash.py and ADR-0025:\n"
        f"{file_list}\n"
        "\n"
        "  Audit column only, never a fingerprint input, never gates reprocessing. CI\n"
        "  recomputes this on every change and fails the build if it disagrees with what's\n"
        "  checked in here, so a stale value is a blocked merge, not a silent gap.\n"
        "-#}\n"
        "\n"
        "{% macro embedding_logic_hash() -%}\n"
        f"    {{{{ return('{hash_value}') }}}}\n"
        "{%- endmacro %}\n"
    )
    GENERATED_MACRO_PATH.write_text(content)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--generate", action="store_true", help="recompute and rewrite the checked-in literal"
    )
    args = parser.parse_args()

    files = walk_call_graph(ENTRY_FILES)
    current_hash = compute_hash(files)

    if args.generate:
        write_macro(current_hash, files)
        print(f"Generated embedding_logic_hash() = {current_hash}")
        print("File set:")
        for f in files:
            print(f"  {f.relative_to(REPO_ROOT)}")
        return 0

    checked_in_hash = read_checked_in_hash()
    if checked_in_hash != current_hash:
        print("embedding_logic_hash() is STALE.")
        print(f"  checked in: {checked_in_hash}")
        print(f"  computed:   {current_hash}")
        print("Run: python ci/verify_embedding_logic_hash.py --generate")
        return 1

    print(f"embedding_logic_hash() OK ({current_hash})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

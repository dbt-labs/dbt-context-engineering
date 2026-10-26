#!/usr/bin/env python3
"""Verify or generate embedding_logic_hash()'s content hash.

embedding_logic_hash() identifies the embedding-relevant source in this package for audit
purposes, never for gating reprocessing (see ADR-0025). The file set is derived by walking
embed()'s call graph from macros/functions/embed.sql rather than hand-listed, so a
newly-relevant file is picked up automatically the next time this script runs.

The walk itself lives in ci/macro_call_graph.py, which documents which edges it can and cannot
see. It follows both package-qualified calls and bare adapter.dispatch calls; a macro name
assembled at run time remains invisible to it, per ADR-0025's Consequences section.

Usage:
    python ci/verify_embedding_logic_hash.py            # check mode (default), exits 1 if stale
    python ci/verify_embedding_logic_hash.py --generate  # recompute and rewrite the checked-in literal
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path

from macro_call_graph import MACROS_DIR, REPO_ROOT, walk_call_graph

ENTRY_FILES = [MACROS_DIR / "functions" / "embed.sql"]
GENERATED_MACRO_PATH = MACROS_DIR / "embedding" / "embedding_logic_hash.sql"

HASH_LITERAL_PATTERN = re.compile(r"return\(\s*'([0-9a-f]{64})'\s*\)")


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

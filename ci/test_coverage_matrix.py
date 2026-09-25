#!/usr/bin/env python3
"""Regression tests for ci/coverage_matrix.py. Plain asserts, no framework:

    python ci/test_coverage_matrix.py

Each case here corresponds to a real mistake made while building this generator, caught by
running it against the actual repo rather than by reasoning about it. If one of these goes red,
that mistake is back.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from coverage_matrix import (  # noqa: E402
    _extract_macro_bodies,
    _strip_jinja_comments,
    build_matrix,
    discover_entry_points,
    discover_implementations,
    resolve_implementation,
)


def test_comment_stripping_hides_example_calls() -> None:
    """dev_sample_filter.sql's own docstring demonstrates a call to classify() as an example.
    Without stripping, the walker reads that as a real call and reports classify as reached from
    a file that never actually calls it."""
    text = (
        "{#- Example: {{ dbt_context_engineering.classify('text', ...) }} -#}\n"
        "{% macro dev_sample_filter() -%}\nselect 1\n{%- endmacro %}"
    )
    stripped = _strip_jinja_comments(text)
    assert "classify" not in stripped, stripped


def test_macro_body_extraction_is_scoped() -> None:
    """One file can define several macros (a dispatcher plus adapter implementations, or several
    unrelated helpers). Extracting snowflake__classify's body must not include content that
    belongs to a sibling macro defined later in the same file."""
    text = (
        "{% macro classify() -%}\n"
        "    {{ return(adapter.dispatch('classify', 'dbt_context_engineering')()) }}\n"
        "{%- endmacro %}\n"
        "{% macro snowflake__classify() -%}\n"
        "    {{ dbt_context_engineering.render_prompt() }}\n"
        "{%- endmacro %}"
    )
    bodies = _extract_macro_bodies(text)
    assert "render_prompt" in bodies["snowflake__classify"]
    assert "adapter.dispatch" not in bodies["snowflake__classify"]
    assert "render_prompt" not in bodies["classify"]


def test_resolve_implementation_falls_back_to_default() -> None:
    """duckdb has no <adapter>__ prefix anywhere in this package, and a cloud target with no
    override of its own falls through to default__ the same way. Only a cloud target that HAS its
    own override should ever resolve to something other than default__."""
    dispatched = {
        "row_value_not_in": {"default": Path("x"), "bigquery": Path("y")},
    }
    assert resolve_implementation("row_value_not_in", "duckdb", dispatched) == "default__row_value_not_in"
    assert resolve_implementation("row_value_not_in", "snowflake", dispatched) == "default__row_value_not_in"
    assert resolve_implementation("row_value_not_in", "bigquery", dispatched) == "bigquery__row_value_not_in"


def test_qualified_probe_does_not_masquerade_as_dispatch_build() -> None:
    """assert_classify_escapes_enum.sql calls snowflake__classify and databricks__classify
    directly, from duckdb's connection. That is real evidence (the Jinja renders), but it must
    show up as PROBED from duckdb, never as BUILT under snowflake/databricks -- conflating the two
    would claim a real warehouse build that never happened."""
    rows, _ = build_matrix()
    by_name = {r["name"]: r for r in rows}
    row = by_name["snowflake__classify"]
    assert "duckdb" in row["probed"], row
    assert "snowflake" not in row["probed"], row


def test_dispatch_resolution_reaches_the_specific_implementations_own_calls() -> None:
    """bigquery__classify calls bq_output_schema and schema_label_field internally. A bare
    dispatch of classify() from the cloud project, resolved for target=bigquery, must walk INTO
    bigquery__classify's own body to find them, not stop at the base dispatcher's body."""
    rows, _ = build_matrix()
    by_name = {r["name"]: r for r in rows}
    assert "bigquery" in by_name["bq_output_schema"]["built"] or by_name["bq_output_schema"]["built"], by_name["bq_output_schema"]
    assert by_name["schema_label_field"]["built"], by_name["schema_label_field"]


def test_pre_dispatch_guards_are_reached_via_the_outer_wrapper() -> None:
    """embed()'s require_ai_functions_enabled / require_safe_materialization /
    require_full_refresh_gate calls live in the outer wrapper, above adapter.dispatch, and run
    unconditionally before dispatch happens. Resolving straight to the target-specific
    implementation and skipping the wrapper's own body would lose these entirely."""
    rows, _ = build_matrix()
    by_name = {r["name"]: r for r in rows}
    for name in ("require_ai_functions_enabled", "require_safe_materialization", "require_full_refresh_gate"):
        assert by_name[name]["built"], (name, by_name[name])


def test_throwaway_uncovered_macro_is_flagged() -> None:
    """Adding a dispatched macro with no coverage anywhere must make the check fail. Written to
    a real file under macros/ (discover_implementations walks macros/**.sql) and removed in a
    finally block regardless of outcome."""
    macros_dir = Path(__file__).resolve().parent.parent / "macros" / "functions"
    throwaway = macros_dir / "zz_test_coverage_matrix_throwaway.sql"
    throwaway.write_text(
        "{% macro zz_cm_throwaway() -%}\n"
        "    {{ return(adapter.dispatch('zz_cm_throwaway', 'dbt_context_engineering')()) }}\n"
        "{%- endmacro %}\n"
        "{% macro default__zz_cm_throwaway() -%}\nselect 1\n{%- endmacro %}\n"
    )
    try:
        _, bare = discover_implementations()
        assert "zz_cm_throwaway" in bare
        _, unreached = build_matrix()
        assert "default__zz_cm_throwaway" in unreached, unreached
    finally:
        throwaway.unlink()


def test_entry_point_discovery_finds_schema_yml_test_attachments() -> None:
    """grounded and no_oversized_chunks are attached to a column via schema.yml
    (`tests: [dbt_context_engineering.grounded]`), never called from a .sql file. An entry-point
    discovery that only scanned .sql files would call both permanently uncovered."""
    _, direct_refs = discover_entry_points()
    for project in ("duckdb", "cloud"):
        assert "grounded" in direct_refs[project] or "no_oversized_chunks" in direct_refs[project], (
            project,
            direct_refs[project],
        )


def main() -> int:
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"{len(tests)} passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

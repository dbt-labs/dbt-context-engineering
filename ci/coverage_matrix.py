#!/usr/bin/env python3
"""Generate and verify the credential-free coverage matrix.

Prose maintained by hand, the shape the README and TESTING.md's §4 tables use for everything
else, has no way to notice when a shipped implementation is missing from it. A macro
implementation can ship with no coverage anywhere and nothing notices: create_vector_index's four
implementations, require_databricks_ai_runtime, and require_bq_model all reached main unexecuted
before someone went looking by hand. A generated matrix, computed from the call graph, cannot
drift from the code the same way, since it IS a computation over the code.

This generates COVERAGE_MATRIX.md from two different kinds of source, and does not blur them
together.

COMPUTED, automatically, from the call graph (ci/macro_call_graph.py, the same walker
embedding_logic_hash uses): for every dispatched macro's four implementations
(default__/snowflake__/databricks__/bigquery__), which ones are reached by a real `dbt build` of
the duckdb project or the cloud project against a real target. This is the strong evidence: the
implementation dbt actually resolves to and runs when that project builds under that target.

Also computed: which implementations are reached by a DIRECT, package-qualified call to that
exact name (`dbt_context_engineering.snowflake__create_vector_index(...)`), as opposed to a bare
dispatch of the base name. This happens when a probe deliberately calls one specific
implementation regardless of which connection is active, the pattern this package's own raise
probes and DDL-assembly assertions use (see integration_tests/duckdb/macros/
assert_create_vector_index.sql, run via `dbt run-operation` from ci.yml, always against the
duckdb connection). It proves the Jinja renders without a Python-level crash. It does NOT prove
the resulting SQL is accepted by the warehouse that implementation is named for, since the probe
may not be connected to one.

DECLARED, by a human, in ci/coverage_exceptions.yml: every implementation the computed pass finds
completely unreached needs an entry there saying how it is actually validated instead (a manual
procedure documented in TESTING.md, deletion pending, or similar). check() fails the build if an
unreached implementation has no exception entry, which is finding 2's gate: new dispatched SQL
cannot ship with silent, undeclared coverage.

What this cannot compute, and does not pretend to: whether a build that reaches an implementation
also ASSERTS something about its output, versus merely executing it without erroring. That is a
judgment call about test semantics, not a property of the call graph, and TESTING.md's own §4
tables are where that distinction is recorded in prose, deliberately, one capability at a time.

Usage:
    python ci/coverage_matrix.py            # check mode (default), exits 1 if the checked-in
                                             # matrix disagrees with a fresh computation, or if
                                             # anything unreached lacks an exception entry
    python ci/coverage_matrix.py --generate # recompute and rewrite COVERAGE_MATRIX.md
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from macro_call_graph import (  # noqa: E402
    MACROS_DIR,
    REPO_ROOT,
    _find_defining_files,
    called_macro_names,
)

JINJA_COMMENT_PATTERN = re.compile(r"\{#-?.*?-?#\}", re.DOTALL)

INTEGRATION_DIR = REPO_ROOT / "integration_tests"
CI_YML = REPO_ROOT / ".github" / "workflows" / "ci.yml"
EXCEPTIONS_FILE = Path(__file__).resolve().parent / "coverage_exceptions.yml"
MATRIX_FILE = REPO_ROOT / "COVERAGE_MATRIX.md"

ADAPTERS = ["default", "snowflake", "databricks", "bigquery"]
ALL_TARGETS = ["duckdb", "snowflake", "databricks", "bigquery"]
CLOUD_TARGETS = ["snowflake", "databricks", "bigquery"]

DEF_PATTERN = re.compile(r"\{%-?\s*(?:macro|test)\s+(\w+)\s*\(")
RUN_OP_PATTERN = re.compile(r"run-operation\s+(\w+)")
PROJECT_DIR_PATTERN = re.compile(r"--project-dir\s+(\S+)")


def discover_implementations() -> tuple[dict[str, dict[str, Path]], dict[str, Path]]:
    """Every macro/test defined anywhere in macros/, split into dispatched base names (mapped to
    each adapter implementation that exists for them) and bare, single-implementation names.
    Leading-underscore helpers (_ce_scalar_vector_search, _ce_str_literal) are shared builders
    behind a public dispatcher, not a shipped capability with their own coverage story, so they
    are dropped from the bare set rather than reported as uncovered."""
    all_defs: dict[str, Path] = {}
    for f in sorted(MACROS_DIR.rglob("*.sql")):
        for m in DEF_PATTERN.finditer(f.read_text()):
            all_defs.setdefault(m.group(1), f)

    dispatched: dict[str, dict[str, Path]] = {}
    bare: dict[str, Path] = {}
    for name, f in all_defs.items():
        matched_adapter = None
        for a in ADAPTERS:
            if name.startswith(a + "__"):
                matched_adapter = a
                break
        if matched_adapter is not None:
            base = name[len(matched_adapter) + 2 :]
            dispatched.setdefault(base, {})[matched_adapter] = f
        else:
            bare[name] = f

    bare = {n: f for n, f in bare.items() if not n.startswith("_")}
    return dispatched, bare


# Package models the integration projects enable via their own dbt_project.yml config, and so
# genuinely build even though they live outside integration_tests/. Both are enabled in both
# projects today (confirmed against each project's `models:` block). This is a hand-kept list
# rather than a YAML parse because dbt_project.yml's config-inheritance rules (+enabled at
# various nesting levels) are not worth reimplementing here for two models.
PACKAGE_ENTRY_FILES = [
    REPO_ROOT / "models" / "audit" / "ai_run_log.sql",
    REPO_ROOT / "models" / "monitoring" / "embedding_canary.sql",
] + sorted((REPO_ROOT / "tests").glob("*.sql"))
PACKAGE_ENTRY_MODELS = {"duckdb": PACKAGE_ENTRY_FILES, "cloud": PACKAGE_ENTRY_FILES}

YAML_TEST_REF_PATTERN = re.compile(r"dbt_context_engineering\.(\w+)")


def _strip_jinja_comments(text: str) -> str:
    """macro_call_graph.py's shared walker (embedding_logic_hash's gate) matches raw text, so a
    Jinja comment showing an EXAMPLE call, e.g. dev_sample_filter.sql's own docstring
    demonstrating a call to classify(), reads as a real one. That is harmless for the hash gate,
    which only ever over-includes a file it did not strictly need. It is not harmless here: a
    coverage matrix that counts example code in a comment as real coverage is reporting false
    confidence, the exact failure mode this PR exists to close. Stripped only for THIS module's
    own walk, not for the shared walker itself, so the checked-in embedding_logic_hash literal
    (already committed, already reviewed) does not change underneath an unrelated PR."""
    return JINJA_COMMENT_PATTERN.sub("", text)


MACRO_START_PATTERN = re.compile(r"\{%-?\s*(macro|test)\s+(\w+)\s*\(")


def _extract_macro_bodies(text: str) -> dict[str, str]:
    """Split a file's (comment-stripped) text into {macro_name: its own body}, matching each
    {% macro/test NAME(...) %} block up to its {% endmacro %}/{% endtest %}. Naive: this codebase
    never nests a macro definition inside another, so 'up to the next {% macro %} start, or the
    matching end tag, whichever comes first' is exact, not a heuristic."""
    bodies: dict[str, str] = {}
    starts = list(MACRO_START_PATTERN.finditer(text))
    for i, m in enumerate(starts):
        kind, name = m.group(1), m.group(2)
        start = m.start()
        end_bound = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        region = text[start:end_bound]
        end_tag = "endmacro" if kind == "macro" else "endtest"
        end_match = re.search(r"\{%-?\s*" + end_tag + r"\s*-?%\}", region)
        bodies[name] = region[: end_match.end()] if end_match else region
    return bodies


def resolve_implementation(base: str, target: str, dispatched: dict[str, dict[str, Path]]) -> str:
    """What adapter.dispatch resolves a bare call to `base` into, for `target`. There is no
    duckdb__ prefix anywhere in this package, so duckdb always falls through to default__ the
    same way a cloud target without its own override does. Only meaningful for a `base` that IS a
    dispatched name. Callers check that first."""
    variants = dispatched.get(base, {})
    if target in CLOUD_TARGETS and target in variants:
        return f"{target}__{base}"
    return f"default__{base}"


def walk_target(
    entries: list, seed_names: set[str], target: str, dispatched: dict[str, dict[str, Path]]
) -> set[str]:
    """Names reached when `entries` (plus any bare `seed_names`, for a schema.yml/hook reference
    with no file to walk) build under `target`. Reuses macro_call_graph.py's patterns and
    file-lookup (called_macro_names, _find_defining_files), with fixes that module's file-level
    walk does not need for its own purpose (the hash gate only cares which files might be
    relevant, and over-inclusion there is harmless).

    A bare dispatch of a name in `dispatched` resolves IMMEDIATELY to that target's specific
    implementation, and the walk continues into THAT implementation's own body, not the tiny
    dispatcher wrapper's. Doing this resolution as the walk happens, rather than as a label
    applied afterward, is what lets a call made from INSIDE a specific implementation get
    followed at all: bigquery__classify calls bq_output_schema and schema_label_field, and only
    resolving "classify under bigquery" to "bigquery__classify" before recursing finds them.

    Every hop is also scoped to the specific macro's own body once one is known (see
    _extract_macro_bodies), not its whole file, and Jinja comments are stripped first, so a
    docstring's example call (dev_sample_filter.sql demonstrates classify() in a comment) is not
    read as a real one and an unrelated sibling definition living in the same file is not either.
    Confirmed live: without body-scoping, walking to snowflake__classify's definition (to see
    what it calls) also re-scanned classify.sql's unrelated base dispatcher sitting in the same
    file, producing a phantom "classify is dispatched here" edge nothing actually exercised."""
    all_sql_files = sorted(MACROS_DIR.rglob("*.sql"))
    directly_named: set[str] = set()
    queue: list[tuple[Path, str | None]] = list(entries)
    seen: set[tuple[Path, str | None]] = set()

    def _enqueue_body(name: str) -> None:
        for f in _find_defining_files(name, all_sql_files):
            item = (f, name)
            if item not in seen:
                queue.append(item)

    def _reach(name: str) -> None:
        """`name` was literally found as a call, or is a seed name a project's config invokes
        directly, so it belongs in directly_named: the return value compute_reachability
        classifies. A dispatched base name ALSO gets its target-resolved implementation's body
        enqueued for traversal (post-dispatch logic, specific to that adapter), and its own outer
        wrapper's body (pre-dispatch logic runs there unconditionally, e.g. embed()'s
        require_ai_functions_enabled / require_safe_materialization / require_full_refresh_gate
        calls, which fire before adapter.dispatch is ever reached). The RESOLVED name itself is
        deliberately NOT added to directly_named: it was never actually written anywhere as a
        qualified call, only computed here as where dispatch sends it, and conflating the two
        would make every normally-dispatched implementation also read as "probed", diluting that
        column into meaninglessness."""
        directly_named.add(name)
        _enqueue_body(name)
        if name in dispatched:
            _enqueue_body(resolve_implementation(name, target, dispatched))

    for name in seed_names:
        _reach(name)

    while queue:
        item = queue.pop()
        if item in seen:
            continue
        seen.add(item)
        current, scope = item

        text = _strip_jinja_comments(current.read_text())
        if scope is not None:
            text = _extract_macro_bodies(text).get(scope, "")

        for name in called_macro_names(text):
            _reach(name)

    return directly_named


def _macro_defining_file(name: str, search_dirs: list[Path]) -> Path | None:
    def_pattern = re.compile(r"\{%-?\s*macro\s+" + re.escape(name) + r"\s*\(")
    for d in search_dirs:
        for f in sorted(d.rglob("*.sql")):
            if def_pattern.search(f.read_text()):
                return f
    return None


EntryPoint = tuple  # (Path, str | None) -- a file, and the specific macro name to scope to
# within it (None means the whole file, correct for a model or test .sql, which is never wrapped
# in its own {% macro %} tag and never shares a file with an unrelated definition).


def discover_entry_points() -> tuple[dict[str, list], dict[str, set[str]]]:
    """Every model and test .sql file in each integration project (what `dbt build` actually
    runs), the package's own models an integration project's config enables
    (PACKAGE_ENTRY_MODELS), every macro invoked via `dbt run-operation <name>` in ci.yml (resolved
    to its defining file wherever it actually lives, an integration-local macros/ directory or
    the package's own macros/), and every `dbt_context_engineering.<name>` reference inside a
    schema.yml or dbt_project.yml, which is how a generic test is attached and how an on-run-start
    hook fires and neither ever appears as a `.sql` file calling anything.

    Returns (file_entry_points, direct_name_references). The second covers the schema.yml/
    dbt_project.yml case, where there is no sensible '.sql file' to hand to the walker, only a bare
    name a project's config invokes directly. Those are folded into reachability the same way a
    run-operation is, as a direct call from that project's connection."""
    entry_points: dict[str, list] = {"duckdb": [], "cloud": []}
    direct_refs: dict[str, set[str]] = {"duckdb": set(), "cloud": set()}

    for project in entry_points:
        proj_dir = INTEGRATION_DIR / project
        for sub in ("models", "tests"):
            entry_points[project].extend(
                (f, None) for f in sorted((proj_dir / sub).rglob("*.sql"))
            )
        entry_points[project].extend((f, None) for f in PACKAGE_ENTRY_MODELS[project])

        EXCLUDED_DIRS = {"target", "dbt_packages", ".venv"}
        for yml in proj_dir.rglob("*.yml"):
            if yml.is_dir() or EXCLUDED_DIRS & set(yml.relative_to(proj_dir).parts):
                continue
            direct_refs[project] |= set(YAML_TEST_REF_PATTERN.findall(yml.read_text()))

    lines = CI_YML.read_text().split("\n")
    for i, line in enumerate(lines):
        m = RUN_OP_PATTERN.search(line)
        if not m:
            continue
        op_name = m.group(1)
        proj_dir_str = None
        for j in range(i, min(i + 4, len(lines))):
            pm = PROJECT_DIR_PATTERN.search(lines[j])
            if pm:
                proj_dir_str = pm.group(1)
                break
        if proj_dir_str is None:
            continue
        project = (
            "duckdb" if "duckdb" in proj_dir_str else "cloud" if "cloud" in proj_dir_str else None
        )
        if project is None:
            continue
        # The macro's OWN name is directly invoked (`dbt run-operation <op_name>`), which is an
        # edge nothing inside op_name's own file can represent -- a macro's definition never
        # calls itself by name. Its defining file is ALSO added as an entry point so anything
        # op_name calls internally is walked too (print_embedding_canary calls
        # canary_vector_to_json, for instance, and that edge matters here as much as it would
        # from any other entry point).
        direct_refs[project].add(op_name)
        f = _macro_defining_file(
            op_name, [INTEGRATION_DIR / project / "macros", MACROS_DIR]
        )
        # Scoped to op_name specifically: this file may define sibling macros (probes,
        # assertions) that this particular run-operation never touches.
        if f is not None and (f, op_name) not in entry_points[project]:
            entry_points[project].append((f, op_name))

    return entry_points, direct_refs


def compute_reachability(
    entry_points: dict[str, list],
    direct_refs: dict[str, set[str]],
    dispatched: dict[str, dict[str, Path]],
) -> tuple[set[tuple[str, str]], dict[str, set[str]]]:
    """dispatch_reached: {(base_name, target)} -- a bare dispatch of base_name was made from an
    entry point in the project that genuinely builds under target. qualified_reached: {impl_name:
    {project, ...}} -- a direct, package-qualified call named that exact implementation, from an
    entry point in that project, on any of its targets. Runs one walk per (project, target) pair
    rather than one combined walk per project, since which implementation a bare dispatch resolves
    to, and therefore what it transitively calls, depends on the target."""
    dispatch_reached: set[tuple[str, str]] = set()
    qualified_reached: dict[str, set[str]] = {}

    all_impl_names = {
        f"{a}__{base}" for base, variants in dispatched.items() for a in variants
    }

    for project, entries in entry_points.items():
        targets = ["duckdb"] if project == "duckdb" else CLOUD_TARGETS
        for target in targets:
            names = walk_target(entries, direct_refs.get(project, set()), target, dispatched)
            for name in names:
                if name in all_impl_names:
                    # A bare, single-implementation name (no adapter prefix at all) is treated the
                    # same as a dispatched base name here: reached under this target, full stop.
                    # It is not in all_impl_names, so this branch is dispatched-implementation
                    # names only.
                    qualified_reached.setdefault(name, set()).add(project)
                else:
                    dispatch_reached.add((name, target))

    return dispatch_reached, qualified_reached


def load_exceptions() -> dict[str, str]:
    """A tiny hand-maintained YAML map of implementation-or-bare-name -> one-line reason it is
    validated some other way. Not parsed with a YAML library to avoid adding a dependency for two
    lines of syntax (`key: value`, `#` comments, blank lines). Anything more structured than that
    is a sign this file has outgrown this parser and should move to real YAML."""
    if not EXCEPTIONS_FILE.exists():
        return {}
    out = {}
    for line in EXCEPTIONS_FILE.read_text().split("\n"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, reason = line.partition(":")
        out[key.strip()] = reason.strip()
    return out


def build_matrix() -> tuple[list[dict], list[str]]:
    """Returns (rows, unreached_without_exception). Each row is one implementation or bare macro
    with its evidence per target. unreached_without_exception is every implementation the computed
    pass never touches and ci/coverage_exceptions.yml never mentions -- check() fails the build on
    a non-empty list."""
    dispatched, bare = discover_implementations()
    entry_points, direct_refs = discover_entry_points()
    dispatch_reached, qualified_reached = compute_reachability(entry_points, direct_refs, dispatched)
    exceptions = load_exceptions()

    rows = []
    unreached = []

    for base in sorted(dispatched):
        variants = dispatched[base]
        for adapter in ADAPTERS:
            if adapter not in variants:
                continue
            impl_name = f"{adapter}__{base}"
            targets_built = [
                t
                for t in ALL_TARGETS
                if resolve_implementation(base, t, dispatched) == impl_name
                and (base, t) in dispatch_reached
            ]
            probed_from = sorted(qualified_reached.get(impl_name, set()))
            exception = exceptions.get(impl_name)
            if not targets_built and not probed_from and exception is None:
                unreached.append(impl_name)
            rows.append(
                {
                    "name": impl_name,
                    "built": targets_built,
                    "probed": probed_from,
                    "exception": exception,
                }
            )

    for name in sorted(bare):
        # A bare macro has exactly one implementation, portable across engines by construction,
        # so unlike a dispatched implementation there is no per-target branch to prove separately.
        # Still reported as the SPECIFIC targets it was actually reached under, not blanket-claimed
        # as all four on any single hit: a bare wrapper running fine on duckdb says nothing about
        # whatever DISPATCHED macro it calls internally on a target it was never reached under.
        targets_built = sorted(t for t in ALL_TARGETS if (name, t) in dispatch_reached)
        probed_from = sorted(qualified_reached.get(name, set()))
        exception = exceptions.get(name)
        if not targets_built and not probed_from and exception is None:
            unreached.append(name)
        rows.append(
            {
                "name": name,
                "built": targets_built,
                "probed": probed_from,
                "exception": exception,
            }
        )

    return rows, unreached


def render_matrix(rows: list[dict]) -> str:
    lines = [
        "<!-- GENERATED by ci/coverage_matrix.py --generate. Do not hand-edit. -->",
        "",
        "# Coverage matrix",
        "",
        "**Built** -- a real `dbt build` of that project genuinely dispatches to this",
        "implementation for that target. The strong signal: real `adapter.dispatch` resolution,",
        "real target.",
        "",
        "**Probed** -- a direct, package-qualified call names this exact implementation from a",
        "run-operation or model, regardless of which connection is active. Proves the Jinja",
        "renders. It does not by itself prove the SQL is accepted by the warehouse it is named",
        "for. Listed by which project's connection it ran under, not by the implementation's own",
        "adapter name: the duckdb project genuinely probes `snowflake__create_vector_index`, for",
        "example, entirely without a Snowflake connection.",
        "",
        "**Exception** -- declared in `ci/coverage_exceptions.yml`: unreached by both of the",
        "above, validated some other way. See TESTING.md for the procedure each exception names.",
        "",
        "See `ci/coverage_matrix.py`'s own module docstring for what this table can and cannot",
        "prove.",
        "",
        "| Implementation | Built | Probed | Exception |",
        "|---|---|---|---|",
    ]
    for row in rows:
        built = ", ".join(row["built"]) if row["built"] else ""
        probed = ", ".join(row["probed"]) if row["probed"] else ""
        exc = row["exception"] or ""
        lines.append(f"| `{row['name']}` | {built} | {probed} | {exc} |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--generate", action="store_true", help="recompute and rewrite COVERAGE_MATRIX.md"
    )
    args = parser.parse_args()

    rows, unreached = build_matrix()
    content = render_matrix(rows)

    if args.generate:
        MATRIX_FILE.write_text(content)
        print(f"Generated {MATRIX_FILE.relative_to(REPO_ROOT)} ({len(rows)} rows)")
        if unreached:
            print(f"\n{len(unreached)} implementation(s) have no coverage and no exception entry:")
            for name in unreached:
                print(f"  {name}")
            print(f"\nAdd an entry to {EXCEPTIONS_FILE.relative_to(REPO_ROOT)} for each, or cover it.")
            return 1
        return 0

    if unreached:
        print(f"{len(unreached)} implementation(s) have no coverage and no exception entry:")
        for name in unreached:
            print(f"  {name}")
        print(f"\nAdd an entry to {EXCEPTIONS_FILE.relative_to(REPO_ROOT)} for each, or cover it.")
        return 1

    if not MATRIX_FILE.exists():
        print(f"{MATRIX_FILE.relative_to(REPO_ROOT)} does not exist. Run --generate.")
        return 1

    checked_in = MATRIX_FILE.read_text()
    if checked_in != content:
        print("COVERAGE_MATRIX.md is STALE.")
        print("Run: python ci/coverage_matrix.py --generate")
        return 1

    print(f"COVERAGE_MATRIX.md OK ({len(rows)} rows, 0 unreached without an exception)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

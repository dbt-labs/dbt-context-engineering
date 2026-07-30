# 6. Teardown works on every integration platform to support iteration

- Status: Accepted
- Date: 2026-07-30

## Context

Building and validating the package is an iterative loop: build the models on a platform, inspect the
output, change something, and rebuild. That loop is only reliable if a platform can be reset to a
clean state between runs. Otherwise stale objects from a previous build linger and can mask or corrupt
what the next run produces.

The package targets four platforms (Snowflake, Databricks, BigQuery, and duckdb), so the reset has to
work on all of them, not just the one a developer happens to favor. A teardown that exists on only one
tier would make iteration uneven and leave the others to accumulate stale state.

## Decision

We will provide a teardown capability on every integration tier so the build, inspect, and rebuild
loop is the same everywhere. Each cloud project (Snowflake, Databricks, BigQuery) has a `ce_teardown`
run-operation; duckdb resets by deleting its local database file. The teardown and rebuild cycle these
enable is what we run to validate a change across all tiers.

The cloud macro is graph-driven and scoped to the current target's database and schema, and defaults
to a dry run. That scoping is a safety foundation, not the reason the macro exists: in a shared dev
schema it guarantees teardown only ever drops what the project's own manifest built.

## Consequences

Iteration is uniform across all four tiers, and a full teardown-and-rebuild is a routine, low-risk
step rather than a manual cleanup. This is the mechanism behind the from-scratch validation runs used
throughout development.

The safety scoping means teardown cannot drop objects the project does not own, and dry-run-by-default
guards against an accidental invocation. The one cost of that scoping is orphans on rename: because
teardown only knows the current manifest, renaming a model leaves the old name's table behind. We
accept that rare, manual cleanup as the price of never touching objects outside the project.

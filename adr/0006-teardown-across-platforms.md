# 6. Teardown works on every integration platform to support iteration

- Status: Accepted
- Date: 2026-07-30

## Concept

Iteration is a loop: **build, inspect, change, rebuild**. The loop is only trustworthy if each pass
starts from a clean state. Stale objects left by a previous build can mask a regression or corrupt
what the next run produces, so a **reliable reset** is a precondition for iterating at all, not a
convenience.

Two further principles shape the reset. It must be **uniform across platforms**, because a reset
that exists on only one tier makes iteration uneven and lets the others accumulate stale state. And
on a **shared schema** it must be **safe by construction**, dropping only what the project itself
built, because the alternative is trusting a developer to never point it at the wrong place.

## Context

The package targets four platforms: Snowflake, Databricks, BigQuery, and duckdb. Validating a change
means tearing down and rebuilding on each, so the reset has to work everywhere, not just on the tier
a developer favors.

The cloud tiers add a constraint. Their target may be a **shared dev schema**, not one owned
exclusively by this project, so a reset must never touch anything the project did not build. An
earlier version listed the objects to drop by hand, which drifts silently as models are added and
removed.

Two ways to know what to drop:

1. **A hand-maintained list of objects.** Drifts out of sync the moment a model is added or removed,
   and has no inherent notion of what the project actually owns.
2. **The project's own build graph.** dbt already knows every model and seed it builds and where.
   Driving teardown from the graph makes the drop set self-updating and ownership-aware. This is the
   path we chose.

## Decision

**We will provide a graph-driven `ce_teardown` on every integration tier, scoped to the current
target and defaulting to a dry run.** Each cloud project (Snowflake, Databricks, BigQuery) has a
`ce_teardown` run-operation; duckdb resets by deleting its local database file.

```bash
# preview (default): logs what it would drop, drops nothing
dbt run-operation ce_teardown --project-dir integration_tests/snowflake

# execute
dbt run-operation ce_teardown --project-dir integration_tests/snowflake --args "{'dry_run': false}"
```

The cloud macro walks `graph.nodes` rather than a hand-maintained list. It drops a node only when
the node's own configured `database`/`schema` equal `target.database`/`target.schema`, and even then
issues the drop at the current target via `api.Relation.create`, which quotes correctly per adapter
where plain string concatenation would break on BigQuery project IDs containing hyphens.

## Reasoning

**Why teardown must exist on every tier.** A change is only validated when it has been torn down and
rebuilt cleanly on all four platforms. If the reset exists on only one, the others drift into a
state no one fully controls, and a "passing" rebuild there proves less than it appears to.

**Why graph-driven, not a hardcoded list.** The set of objects the project builds changes every time
a model is added or renamed. A hand-maintained list falls behind silently, leaving orphans it no
longer knows to drop. The build graph is already the authoritative record of what the project
builds, so deriving the drop set from it keeps teardown correct for free.

**Why target-scoped and dry-run by default.** The cloud target is a shared schema, so the cost of a
mistake is dropping someone else's object. Scoping every drop to the current target means teardown
cannot reach outside what the project owns even by construction, and defaulting to a dry run means an
accidental invocation previews rather than executes. `api.Relation.create` is used instead of string
concatenation because it quotes identifiers correctly per adapter, which string building does not on
hyphenated BigQuery project IDs.

## Consequences

- **Iteration is uniform across all four tiers**, and a full teardown-and-rebuild is a routine,
  low-risk step rather than a manual cleanup. This is the mechanism behind the from-scratch
  validation runs used throughout development.
- **Teardown cannot drop objects the project does not own**, because of the graph-plus-target
  scoping, and **dry-run-by-default** guards against an accidental invocation.
- **The one cost is orphans on rename.** Because teardown only knows the current manifest, renaming
  a model leaves the old name's table behind. We accept that rare, manual cleanup as the price of
  never touching objects outside the project.

## Glossary

- **Run-operation**: a dbt command that executes a macro directly (`dbt run-operation`), used here
  to run teardown outside a normal model build.
- **Target**: the database and schema dbt is configured to build into for the current invocation,
  exposed as `target.database` and `target.schema`.
- **Build graph**: dbt's in-memory record of every node it builds, exposed as `graph.nodes`. The
  authoritative, self-updating source of what the project owns.
- **Manifest**: the compiled representation of the project's nodes and config that the graph is
  drawn from. Teardown only knows objects present in the current manifest.
- **Materialization**: how a node is built (table, view, ephemeral). Teardown drops tables and
  views and skips ephemeral nodes, which have no object to drop.
- **`api.Relation.create`**: the dbt API that builds an adapter-correct, properly quoted relation
  reference, used instead of string concatenation so hyphenated BigQuery project IDs quote
  correctly.
- **Dry run**: the default mode that logs what would be dropped without dropping anything; pass
  `dry_run=false` to execute.

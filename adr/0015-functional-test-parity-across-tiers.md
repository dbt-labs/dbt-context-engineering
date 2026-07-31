# 15. Functional test parity across all integration tiers

## Status

Accepted, 2026-07-30.

## Concept

A passing test is only as meaningful as what it asserts. There are two things a build can prove
about a model: that its SQL **compiled and ran** on an engine, and that its **output is correct**. A
model that runs but asserts nothing proves only the first, and a green build that proves only the
first is **misleading**, because it reads like the second.

The principle is **parity of assertion, not just parity of execution**. If a deterministic model
runs on four engines, the same correctness claims should hold on all four. Otherwise the tiers that
build without asserting are decoration, and a per-dialect bug can hide in plain sight behind a green
check.

## Context

The package is tested on four integration projects: a credential-free **duckdb** tier for
deterministic execution, and **Snowflake**, **Databricks**, and **BigQuery** tiers that run real AI
calls. The metadata models were built on all four, but only duckdb asserted anything about them. The
three cloud tiers compiled and ran the models and tested nothing.

That makes a green cloud build misleading. It means "the SQL compiled and ran on this engine," not
"the output is correct." For deterministic models like the metadata attach, which behave identically
on every engine, the cloud copies were effectively decorative, and a per-dialect bug in the
assembled SQL could pass unnoticed, which is precisely the failure mode ADR
[0013](0013-attach-metadata-as-a-separate-macro.md) hit on BigQuery.

Two ways to write the cloud tests:

1. **Engine-specific test bodies per tier.** Lets each test use native functions, but multiplies
   maintenance by four and lets the tiers drift apart.
2. **One portable test body that runs unchanged on every tier.** Constrains the SQL to the portable
   core, but keeps the four tiers provably in step. This is the path we chose.

## Decision

**We will hold the metadata models to functional test parity across all four tiers, with one test
body that runs unchanged on every engine.** Every metadata model carries the same `schema.yml`
generics (uniqueness, not-null) and the same singular asserts (passthrough, in-text,
functional-dependency guard) on duckdb and on all three clouds. The singular SQL is written to be
portable: it casts with `dbt.type_string()` and relies only on `chr()`, `||`, and `like`, which
behave the same on all four.

Parity here means matching tests on models that exist on a tier. It does not require identical model
sets. The cloud AI models have no duckdb analog, and duckdb-only models have no cloud object.

## Reasoning

**Why parity of assertion is the bar.** The whole value of a multi-tier test matrix is catching a
bug that appears on one engine and not another. That value is only realized if each tier asserts
correctness. A tier that builds but does not assert cannot catch anything, so it adds run time and a
false sense of coverage without the coverage.

**Why one portable body rather than four native ones.** Four bodies drift. The moment a test differs
per tier, keeping them equivalent becomes manual work that quietly lapses. Constraining the SQL to
`dbt.type_string()`, `chr()`, `||`, and `like` costs a little expressiveness and buys a single body
that is identical everywhere by construction, so parity cannot silently erode.

**Why `unique(chunk_id)` earns its place twice.** It is both a correctness assertion in its own
right and the tripwire that makes the metadata functional-dependency contract enforceable. A broken
dependency fans out the join and duplicates `chunk_id`, so placing this test on every tier is what
lets that failure surface as red rather than pass silently.

## Consequences

- **A green build means the same thing on every tier**: correct output, not just successful
  compilation.
- **`unique(chunk_id)` doubles as the dependency guard** from
  [0013](0013-attach-metadata-as-a-separate-macro.md), so a broken metadata dependency fails a test
  rather than passing silently.
- **The cost is more test files per project** and the discipline of keeping the four tiers in step
  when a metadata model changes.
- **Full parity for the non-metadata cloud models is out of scope here.** Chunking, splitting, and
  the guard are a larger, separate effort that depends on a further decision a later ADR will
  record: whether to align the cloud chunk models to duckdb's fixture config so the exact-value
  tests port unchanged, or to rewrite those tests as config-independent invariants.

## Glossary

- **Integration tier**: one of the four end-to-end test projects (duckdb, Snowflake, Databricks,
  BigQuery). duckdb is deterministic and credential-free; the clouds run real AI calls.
- **Generic test**: a reusable dbt test attached to a column in `schema.yml`, such as `unique` or
  `not_null`.
- **Singular test**: a one-off dbt test written as a standalone SQL query that fails if it returns
  rows.
- **Functional-dependency guard**: the assertion that each metadata column is constant per key,
  enforced here through the `unique(chunk_id)` test catching a fanned-out join.
- **`dbt.type_string()`**: a dbt macro that emits the current adapter's string type, used so a cast
  compiles on every engine.
- **Portable SQL core**: the constructs (`chr()`, `||`, `like`, and a `dbt.type_string()` cast)
  that behave identically across all four engines, letting one test body run everywhere.

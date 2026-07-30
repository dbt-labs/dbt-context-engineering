# 4. Functional test parity across all integration tiers

- Status: Accepted
- Date: 2026-07-30

## Context

The package is tested on four integration projects: a credential-free duckdb tier for deterministic
execution, and Snowflake, Databricks, and BigQuery tiers that run real AI calls. The metadata models were
added to all four, but only duckdb asserted anything about them. The three cloud tiers built the models and
tested nothing.

That makes a green cloud build misleading. It means "the SQL compiled and ran on this engine," not "the
output is correct." For deterministic models like the metadata attach, which behave identically on every
engine, the cloud copies were effectively decorative, and a per-dialect bug in the assembled SQL could pass
unnoticed.

## Decision

We will hold the metadata models to functional test parity across all four tiers. Every metadata model
carries the same `schema.yml` generics (uniqueness, not-null) and the same singular asserts (passthrough,
in-text, functional-dependency guard) on duckdb and on all three clouds. The singular-test SQL is written
to run unchanged on every engine. It casts with `dbt.type_string()` and relies only on `chr()`, `||`, and
`like`, which behave the same on all four. One test body then runs on every tier.

Parity here means matching tests on models that exist on a tier. It does not require identical model sets:
the cloud AI models have no duckdb analog, and duckdb-only models have no cloud object.

## Consequences

A green build on the metadata models means the same thing on every tier: correct output, not just
successful compilation. The cost is more test files per project and the discipline of keeping the four tiers
in step when a metadata model changes. Full test parity for the pre-existing non-metadata cloud models,
such as chunking, splitting, and the guard, is a larger, separate effort and is out of scope here. It
depends on a further decision that a later ADR will record, namely whether to align the cloud chunk models
to duckdb's fixture config so the exact-value tests port unchanged, or to rewrite those tests as
config-independent invariants.

The `unique(chunk_id)` test this parity places on every tier has a second benefit. It is what lets a broken
metadata dependency surface as a failure rather than pass silently.

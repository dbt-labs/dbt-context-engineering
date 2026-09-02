# 21. Run completion tracked as a boolean, set only by its own post-hook

## Status

Accepted, 2026-08-12. Two of this record's mechanisms are superseded. The unconditional
`ensure_ai_run_log_exists()` self-create is superseded by
[ADR-0030](0030-ai-function-spend-gating-and-ai-run-log-write-safety.md): it raced under
concurrent model execution and is replaced by `create_ai_run_log_table()`, bootstrapped once via
an `on-run-start` hook. The `completed` boolean and its in-place `UPDATE` are superseded by
[ADR-0031](0031-run-completion-as-an-event-sourced-append.md): `UPDATE` conflicted the same
way under concurrency and is replaced by an `event` column written by a second `INSERT`. The
reasoning for needing a completion signal at all, and for tracking it purely in model hooks,
stands.

## Concept

An append-only run log (ADR-0003) tells you a run *started* and roughly what it cost, but not
whether it *finished*. A model that errors mid-run, after `log_ai_run`'s hook has already fired,
leaves a row that looks identical to a healthy in-flight run. Without a durable completion
signal, "still running" and "silently died" are indistinguishable after the fact.

## Context

dbt gives exactly one honest signal here: **a model's `post_hook` never runs when the model
errors.** There is no "on model failure" hook to catch the negative case directly, so the only
way to observe completion is a hook that fires *only on success*, and the absence of that hook
firing is the failure signal.

`ai_run_log` also has to exist before the very first `log_ai_run` call ever writes to it,
including on a `dbt run --select <one_model>` that never builds `ai_run_log` directly.

## Decision

**`ai_run_log` gets a `completed` boolean, not a tri-state status.**

- `log_ai_run` inserts every row at `completed = false`.
- `complete_ai_run`, a post_hook paired on the SAME `function_name`/`model_name`, flips that row
  to `true` once the model finishes successfully.
- A model that errors, is canceled, or is killed simply never reaches that post_hook, so its row
  stays `false`. Nothing else ever revisits or corrects it.
- `ensure_ai_run_log_exists()` guarantees the table exists by issuing an unconditional
  `create table if not exists ... as (...)` every time `log_ai_run` fires, with no existence
  check beforehand. This needs no wiring in any consuming project's `dbt_project.yml`; both
  `log_ai_run` and `complete_ai_run` are ordinary model hooks.

```sql
{{ config(
  post_hook = [
    "{{ dbt_context_engineering.log_ai_run('classify', model_name=var('model_classify')) }}",
    "{{ dbt_context_engineering.complete_ai_run('classify', model_name=var('model_classify')) }}"
  ]
) }}
-- log_ai_run inserts completed = false; complete_ai_run flips it to true once this model succeeds
```

## Reasoning

**Why a boolean instead of a third "did not complete" state.** A third state implies something
actively determined that outcome. Nothing does: dbt only tells you a model succeeded, never that
it failed. Producing a "did not complete" value would require a separate process to infer it
later, and `false` is already the correct value the instant the row is written, so there is
nothing left to infer.

**Why the create is unconditional, with no existence check first.** `log_ai_run` runs as a model
hook, so `ai_run_log` is either already built by dbt itself, if it is selected in this
invocation, dbt's own DAG ordering guarantees that build completes before any hook that
references it can fire, or it is not being built at all this invocation, in which case there is
no other writer to disagree with. Either way, the unconditional statement is a safe no-op or the
sole writer; it never races dbt's own materialization of the same table.

**Why completion lives entirely in model hooks.** A model hook runs inside dbt's normal per-node
transaction wrapping and requires no changes outside the model itself. Nothing about detecting or
recording completion needs to run before the DAG starts, so nothing needs a project-level hook.

## Consequences

- A consuming project adds nothing beyond pairing `log_ai_run` and `complete_ai_run` post_hooks
  on its own AI model; no `dbt_project.yml` changes anywhere.
- There is no proactive alert on an incomplete run. `completed = false` is a fact you query, not
  a push notification, an accepted limitation of inferring completion purely from a hook that
  only fires on success.
- Verified live on all four integration tiers: duckdb (103 passing tests), Snowflake, Databricks,
  and BigQuery (59 passing tests each), including `complete_ai_run`'s `UPDATE` executing
  successfully against all three cloud engines. On duckdb, `ai_run_log` excluded entirely from
  the selected nodes, `log_ai_run` still created it correctly with no collision; and a model that
  never pairs `complete_ai_run` (`logged_never_completed`) stayed `completed = false` across
  repeated invocations, confirmed by `assert_never_completed_stays_false`.
- Extends ADR-0003 without changing it: the guard/meter decisions there are unchanged, this only
  adds a completion signal to the meter's own log.

## Alternatives considered

- **Tri-state status column** (`in process` / `completed` / `did not complete`): rejected. The
  third state can only be produced by a process that runs later and infers it, either a lazy
  correction with no timing guarantee, or a proactive hook requiring wiring in every consuming
  project's `dbt_project.yml`. A boolean default of `false` is already correct the moment the row
  is written, so no such process is needed at all.
- **Checked create** (read for existence, create only if missing): rejected. A read-then-decide
  check can disagree with dbt's own relation cache, and reconciling the two, adopting a
  pre-existing table, syncing the cache after a raw DDL statement, is real, avoidable complexity.
  An unconditional `create table if not exists`, issued every time with no check, needs none of
  that.
- **Schema adoption for a pre-existing table missing the new column**: rejected. The package
  assumes objects are in alignment with their current definition; a full-refresh (or a fresh
  target) always produces the current shape, so there is no pre-existing shape to adopt.

## Glossary

- **`completed`**: the boolean column on `ai_run_log` this ADR adds. `false` from the moment
  `log_ai_run` inserts the row; `true` only once `complete_ai_run`'s post_hook confirms success.
- **Post_hook / model hook**: SQL dbt runs immediately after building a model, inside that
  model's own transaction. Contrasted here with a **project hook** (`on-run-start`/`on-run-end`),
  which runs once per invocation, outside any single model's build, and would need to be declared
  in every consuming project's own `dbt_project.yml`.
- **DAG ordering**: dbt schedules a node only after everything it depends on (via `ref()`,
  including inside a hook) has finished building. This is what guarantees `ai_run_log`'s own
  build, when selected, always completes before any other model's hook that references it fires.
- **Relation cache**: dbt's in-memory record of which relations already exist, populated once per
  invocation. Not touched by this design; the unconditional `create table if not exists` never
  reads it.

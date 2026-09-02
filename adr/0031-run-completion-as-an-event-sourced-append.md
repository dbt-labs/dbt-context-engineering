# 31. Run completion tracked as an event-sourced append, not an in-place update

## Status

Accepted, 2026-09-02.

## Concept

An append-only run log (ADR-0003) needs a durable completion signal (ADR-0021), but recording
that signal cannot require mutating a row that another, independent run might be writing to at
the same moment. **Event sourcing** solves this by never mutating the original row at all:
completion is itself a new row, appended, not a flip of a field on an existing one. Whether a run
finished becomes an existence check, "is there a `'completed'` row for these keys," rather than a
state check, "is this field `true`."

## Context

ADR-0021 gave `ai_run_log` a `completed` boolean: `log_ai_run` inserts a row at `completed =
false`; `complete_ai_run`, a paired post_hook, `UPDATE`s that same row to `true` once the model
finishes.

ADR-0030 found and fixed a *different* concurrency failure on the same table (redundant,
concurrent `CREATE TABLE IF NOT EXISTS` bootstrap attempts), but explicitly left this one
unresolved. Reproducing it directly, isolated from the bootstrap issue: eight independent models,
each pairing `log_ai_run` (an `INSERT`) with `complete_ai_run` (an `UPDATE`), against a table that
already existed, forced onto 8 threads:

```
Databricks: 7 of 8 models failed, DELTA_CONCURRENT_APPEND
BigQuery:   1 of 8 models failed, 429 rate limit
```

The same 8 models, with `complete_ai_run` removed, only `log_ai_run`'s `INSERT` remaining:

```
Databricks: 8 of 8 succeeded
BigQuery:   8 of 8 succeeded
```

The `UPDATE` itself, not the table's existence, is the second root cause. `ai_run_log` is written
by every AI-calling model in a project, on whatever thread dbt schedules it, with no coordination
between models that have no dependency on each other. Two established options were already ruled
out by ADR-0030 for other parts of this same problem, and rule out identically here: serializing
the build (`--threads 1`) discards the concurrency dbt would otherwise give independent models,
and cannot help an unattended scheduled job; retry-with-backoff around the write is infeasible,
Jinja templates have no exception handling, so a macro cannot catch a database error from
`run_query()` and retry.

## Decision

**`ai_run_log` gets an `event` column instead of a `completed` boolean, and `complete_ai_run`
becomes a second `INSERT`, never an `UPDATE`.**

`log_ai_run` inserts one row at `event = 'started'`, exactly as before except for the column name
and value. `complete_ai_run` appends a SEPARATE row for the same invocation at `event =
'completed'`, keyed on the same `invocation_id` + `function_name` + `model_name` its `UPDATE` used
to filter on:

```jinja
insert into {{ ref('ai_run_log') }}
    (invocation_id, model_name, function_name, row_count, est_tokens, est_cost, run_at, event)
select
    '{{ invocation_id }}', {{ model_sql }}, '{{ function_name }}',
    cast(null as {{ dbt.type_int() }}), cast(null as {{ dbt.type_numeric() }}),
    cast(null as {{ dbt.type_numeric() }}),
    cast({{ dbt.current_timestamp() }} as {{ dbt.type_timestamp() }}),
    'completed'
```

A run's completion is read by checking whether a `'completed'` row exists for the same keys as a
`'started'` row, not by reading a column on that same row. `row_count`/`est_tokens`/`est_cost` are
`null` on the `'completed'` row; that data already exists once, on the `'started'` row.

## Reasoning

**Why an append cannot conflict the way an update can.** Two independent `INSERT`s into the same
table are not writes to the same row. Delta's optimistic concurrency control fails a transaction
when a concurrent transaction already committed a newer version of the SAME row or partition it
touched; two 'completed' rows for two different invocations never collide on anything. BigQuery's
DML rate limit counts UPDATE/MERGE operations specifically; a plain INSERT does not compete for
that same limited quota the way the removed UPDATE did.

**Why the join key is unchanged.** `complete_ai_run`'s `UPDATE` already filtered on
`invocation_id`/`function_name`/`model_name` to find the one row `log_ai_run` inserted this
invocation. That same key still uniquely joins a `'completed'` row back to its `'started'` row;
nothing about the matching logic needed to change, only the write itself.

**Why the `'completed'` row carries no sizing data.** `row_count`/`est_tokens`/`est_cost` were
computed once, from a scan of the batch, when `log_ai_run` fired. Recomputing them a second time
for the `'completed'` row would mean re-scanning the same relation for no new information; that
data lives on the `'started'` row, and a query needing both joins the two.

**Why this does not reopen the tri-state question ADR-0021 already closed.** ADR-0021 rejected a
third "did not complete" state because nothing actively determines it, `false` was already correct
the instant `log_ai_run`'s row was written. That reasoning is unchanged here: `'started'` is
written the instant the call begins, `'completed'` is written the instant it succeeds, and the
absence of a `'completed'` row is still read, never written. Event sourcing only changes how
"finished" is recorded (a new row) and how it is read (an existence check instead of a column
read); it does not introduce a state anyone has to infer.

## Consequences

- **Reading "is this run complete" now requires two rows, not one.** A caller must join or
  correlate a `'started'` row to its `'completed'` row on `invocation_id`/`function_name`/
  `model_name`, rather than reading a single boolean column. This is a real query-side cost,
  traded for removing the write-side conflict.
- **`ai_run_log` grows twice as fast.** Every completed run now contributes two rows instead of
  one. The log is already append-only and expected to grow across invocations (ADR-0003); this
  doubles that growth rate.
- **This directly resolves the gap ADR-0030 left open.** ADR-0030's own Consequences section
  states its record does not resolve `complete_ai_run`'s `UPDATE` conflict; this record is that
  resolution.
- **Verified live on all three cloud warehouses under real thread contention**, the same platforms
  ADR-0030's own reproduction targeted: Snowflake (6 threads), Databricks (16 threads), BigQuery
  (16 threads), each a full `--full-refresh` regression build with `ai_functions_enabled: true`
  and every AI-calling model unrestricted (not artificially forced onto extra threads the way the
  original 8-model reproduction was). `assert_run_log`, which checks for exactly one `'started'`
  row plus one matching `'completed'` row per invocation, passed clean on all three; 126 of 126
  tests passed on each with zero errors and zero skips.
- Extends ADR-0021 and ADR-0030 without changing their reasoning about *why* a completion signal is
  needed at all or why the bootstrap race was fixed the way it was; this only changes how the
  completion signal itself is written.

## Alternatives considered

- **Retry-with-backoff around the `UPDATE`.** Rejected, same reasoning as ADR-0030: Jinja macros
  cannot catch a database error and retry.
- **Serializing the build (`--threads 1`).** Rejected, same reasoning as ADR-0030: discards
  concurrency dbt would otherwise give independent models, and does not help an unattended job.
- **A reconciliation process that infers completion after the fact** (e.g. reading dbt's own
  `run_results.json` post-run to backfill a completed flag). Rejected: this requires a mechanism
  outside dbt's own per-model hooks, a project-level step every consuming project would have to
  wire up, the same manual-wiring burden ADR-0030 already accepted only where unavoidable
  (`create_ai_run_log_table`'s `on-run-start` hook), not one to add a second time for a problem an
  append-only write already solves without it.
- **An advisory lock around the `UPDATE`.** Rejected: no portable locking primitive exists across
  duckdb, Snowflake, Databricks, and BigQuery; any such lock would itself be adapter-specific code
  this package would have to maintain and dispatch, to protect a write that a plain `INSERT`
  removes the need for entirely.

## Glossary

- **Event sourcing**: recording a change as a new, immutable fact (an event row) rather than by
  mutating existing state in place. Here, "the run completed" is a fact recorded once, as a new
  row, never a correction applied to an older row.
- **`event`**: the column this ADR adds to `ai_run_log`, replacing `completed`. `'started'` on the
  row `log_ai_run` inserts; `'completed'` on the separate row `complete_ai_run` appends.
- See ADR-0021 and ADR-0030 for **`completed`** (the superseded boolean), **optimistic concurrency
  control**, and **dispatch-layer check**.

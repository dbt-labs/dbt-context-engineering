# 19. Scope the run-log assertion to the current invocation

## Status

Accepted, 2026-07-31.

## Concept

An **append-only log cannot be checked by counting the whole table**. `ce_ai_run_log` is designed to
accumulate one row per AI model run and to persist across dbt invocations. So a test that asserts a
table-wide count is really trying to assert a **per-run** property, that *this* run logged the right
row, using the wrong unit. The correct unit is the **invocation**, not the table.

The post-hook stamps every row with the run's `invocation_id`, and `{{ invocation_id }}` is available
in the test. Scoping the assertion to that value lets a test be both **precise** (verify this run's
row exactly) and **robust** (ignore the accumulated history), which a table-wide count cannot be.

## Context

`assert_run_log` had drifted into two different assertions across the tiers:

- **duckdb** asserted total `count(*) = 1`. Strict, but it only holds when the log is freshly reset,
  and it fails on any second `dbt build` because the log grows.
- **snowflake / databricks / bigquery** asserted "at least one classify row." Robust to accumulation,
  but weak: it cannot catch this run writing a *wrong* row (an older correct row masks it) or a model
  logging *twice*.

Both were workarounds for the same missing idea: scoping to the run. Each tier logs from exactly one
classify model (see [0020](0020-run-log-standin-duckdb-only.md)), so the per-run truth is simply one
classify row per invocation.

## Decision

**All four `assert_run_log` tests scope to the current `invocation_id` and assert the same per-run
contract: exactly one `classify` row for this invocation, valid and sized from the seed using the
*same* `ce_estimate_tokens` and price the logger uses.** Expected values are computed from the
fixture, never magic numbers.

```sql
with log as (
    select * from {{ ref('ce_ai_run_log') }}
    where invocation_id = '{{ invocation_id }}' and function_name = 'classify'
)
-- then: exactly one row, valid and correctly sized
```

The assertion body is identical on all four tiers; only the `depends_on` (the tier's logging model)
differs, because the test must run after the post-hook fires.

## Reasoning

**Why scope to the invocation.** The property under test is per-run: "when a model ran, the post-hook
wrote one correct row." `invocation_id` is exactly that grain. It makes the check robust to the
append-only log without giving up precision.

**Why not a table-wide count.** It conflates "one row this run" with "one row ever," so it breaks the
moment the log is not freshly reset. That is fragile by construction.

**Why not "at least one."** It tolerates accumulation but is too weak: a wrong row hides behind an
older correct one, and double-logging goes undetected. Asserting exactly one row for the invocation
keeps that strength, catching both a missing log and an accidental double-log, without the
table-wide fragility.

## Consequences

- **The teardown-sensitive failure class is gone.** Repeated builds pass because each run only
  asserts its own row. Verified on duckdb across two consecutive builds on an already-accumulated log.
- **The four tiers now assert the same thing** (parity, [0015](0015-functional-test-parity-across-tiers.md)),
  where before duckdb was strict and the clouds lenient.
- **The cloud tests are tightened** from a sanity check to exact per-run correctness: exactly one
  classify row this invocation, with computed `row_count` and `est_tokens`, price-aware `est_cost`,
  and `model_name` present.
- **Each test declares a `depends_on`** for its tier's logging model so it runs after the post-hook.

## Glossary

- **`ce_ai_run_log`**: the append-only usage/cost log; one row is appended per AI model run by the
  `ce_log_ai_run` post-hook, persisting across dbt invocations.
- **`invocation_id`**: dbt's unique id for a single `dbt` run, stamped on each logged row and
  available in Jinja as `{{ invocation_id }}`; the grain this assertion scopes to.
- **Post-hook**: SQL dbt runs after a model builds; here it inserts the run's row into the log, a
  side effect invisible to the DAG, so the test declares an explicit `depends_on`.
- **`ce_estimate_tokens`**: the per-engine token-estimate expression the logger uses to size a batch;
  the test reuses it so expected and logged values match by construction.

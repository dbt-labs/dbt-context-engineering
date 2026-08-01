# 20. The no-AI run-log stand-in exists only on the duckdb tier

## Status

Accepted, 2026-07-31.

## Concept

The cost guard and run log attach to a model as hooks: `ce_guard_batch` as a pre-hook,
`ce_log_ai_run` as a post-hook. To exercise them in a test you need a model whose build fires those
hooks. A tier with a real AI model gets that for free, its classify model already fires them. A tier
with no AI has nothing to attach to, so it needs a **no-AI stand-in**: a model with no AI call whose
only job is to fire the hooks. The stand-in is a substitute for an absent real model, not an extra
check.

## Context

Every tier exercises `ce_log_ai_run` (and `ce_guard_batch`) through a classify model's hooks.
Snowflake and Databricks use their real classify model (`ce_signals_sf` / `ce_signals_dbx`). duckdb
has no AI (`ce_classify` is not implemented there), so it uses a no-AI stand-in, `ce_logged_model`.

bigquery had both: the real `ce_signals_bq` and a no-AI stand-in `ce_logged_bq`. Both fire the same
pre-hook and post-hook over the same fixture, so the stand-in adds no coverage the real model does
not already provide, and it makes bigquery the only tier logging a classify run twice per invocation.

## Decision

**The no-AI stand-in exists only on duckdb. Remove `ce_logged_bq`.** bigquery exercises
`ce_guard_batch` and `ce_log_ai_run` through its real classify model `ce_signals_bq`, matching
Snowflake and Databricks, and `assert_run_log_bq` depends only on `ce_signals_bq` like the other
cloud tiers.

## Reasoning

**Why the stand-in belongs only on duckdb.** It exists to substitute for an absent real AI model.
duckdb has none, so it needs one. The cloud tiers have a real classify model that already fires the
same hooks, so a stand-in there is duplicate coverage, not extra.

**Why remove rather than keep.** The stand-in costs an extra bigquery model and a second classify log
row per run for no additional assertion, and it is the reason bigquery's run-log test had to depend
on two models where the other clouds depend on one.

**Why no coverage is lost.** `ce_guard_batch` is still exercised by `ce_signals_bq`'s pre-hook (and by
the dedicated `ce_guard_pass` circuit-breaker), and `ce_log_ai_run` by `ce_signals_bq`'s post-hook.

## Consequences

- bigquery's model set and its `assert_run_log_bq` match Snowflake and Databricks: one real classify
  logger, one `depends_on`.
- One fewer model on bigquery, and the run log gets one classify row per invocation instead of two.
- The no-AI stand-in pattern is now duckdb-only, which is its only reason to exist.

## Glossary

- **No-AI stand-in model**: a model with no AI call whose only purpose is to fire the `ce_guard_batch`
  and `ce_log_ai_run` hooks so they can be tested on a tier that has no real AI model (duckdb:
  `ce_logged_model`).
- **`ce_log_ai_run` / `ce_guard_batch`**: the post-hook that appends a run to `ce_ai_run_log`, and the
  pre-hook that enforces the batch-size cost ceiling.

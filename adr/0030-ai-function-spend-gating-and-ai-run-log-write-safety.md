# 30. AI function spend gating and ai_run_log write safety

## Status

Accepted, 2026-09-02.

## Concept

Two problems, related only because both are ways an AI-calling package can cost real money or
break a build without anyone intending either.

The first: nothing stops a plain `dbt build`, in a fresh environment or a CI job that never meant
to call a real model, from doing exactly that. A package can ship a helper for this, but a helper
that sits in a config value only protects a caller who remembers to use it. Skipping it is the
easy path, not a deliberate one.

The second: every AI-calling model writes to one shared audit table, `ai_run_log`. dbt schedules
independent models across threads with no coordination between their hooks. If the writes to that
shared table are not safe under concurrent execution, the audit mechanism itself becomes a source
of build failures, on exactly the multi-model architecture this package recommends.

## Context

**The audit-log problem was found twice, independently, on two different platforms, through two
different failure signatures, for two different root causes.**

Two AI-calling models with no dependency on each other, selected in the same `dbt build`, ran on
different threads. On Databricks, the second one's write aborted:

```
[DELTA_CONCURRENT_APPEND.WITHOUT_HINT] Transaction conflict detected. A concurrent UPDATE added
data to table ...ai_run_log committed at version 3. Please retry the operation.
```

Separately, ten independent AI-calling models, selected together on a first build (`ai_run_log`
did not exist yet), produced four failures:

```
429 Exceeded rate limits: too many table update operations for this table.
```

Inspecting BigQuery's own job metadata (`INFORMATION_SCHEMA.JOBS_BY_USER`) confirmed the four
failing jobs were all issuing the identical statement:

```sql
create table if not exists `...`.`ai_run_log` as (select ...)
```

Every AI-calling model's `log_ai_run` pre-hook self-created `ai_run_log` the first time it ran
against a target where the table did not exist, with no coordination across models. Ten models
selected together meant ten redundant, concurrent attempts at the identical DDL.

Reproducing this directly narrowed it further. Two independent models, each writing to
`ai_run_log` via `log_ai_run` (an `INSERT`) followed by `complete_ai_run` (an `UPDATE`), forced
onto 8 threads:

```
Databricks: 7 of 8 models failed, DELTA_CONCURRENT_APPEND
BigQuery:   1 of 8 models failed, 429 rate limit
```

The same 8 models, with `complete_ai_run` removed, only `log_ai_run`'s `INSERT` remaining:

```
Databricks: 8 of 8 succeeded
BigQuery:   8 of 8 succeeded
```

Two distinct root causes, not one: the redundant bootstrap `CREATE TABLE IF NOT EXISTS`, and
`complete_ai_run`'s `UPDATE` conflicting with any other concurrent write to the same table. Fixing
one does not fix the other.

**A config-value opt-in helper does not protect against either problem, or against accidental AI
spend.** A macro like `validated_materialization(value, allowed)`, called as
`config(materialized=validated_materialization(...))`, only fires if a model author routes their
value through it. Writing `materialized='view'` directly bypasses it entirely, and skipping it is
strictly easier than using it. This holds regardless of who controls the code: even in a
package's own shipped models, a future edit can swap the wrapper for a literal without anyone
noticing a guard disappeared.

**A real enforcement point already existed as a pattern.** `require_databricks_serverless()` is
called from inside each AI function's own dispatch chain, not from the caller's `config()`.
Anyone who calls `classify()` unavoidably runs it. `config.get('materialized')` and `var(...)`
both resolve correctly from inside a macro regardless of call depth, the same mechanism
`is_incremental()` already depends on throughout this package.

**Gating that check on `execute` was not optional, it was required to avoid breaking every
build.** dbt renders every model's Jinja during its parse phase to build the manifest, regardless
of `--select`. An unguarded `raise_compiler_error` inside a macro shared by five widely-used
functions fires for every model that calls any of them, whether or not that model was selected
this invocation. Confirmed directly: selecting only two unrelated, non-AI models still failed to
compile, because a third, unselected model in the same project called `generate()`. Only the run
phase (`execute=True`) re-renders the models actually selected; gating on it was the fix, and
matches how `is_incremental()` already avoids acting at parse time.

**A package cannot gate itself the way a package of selectable models can.**
`generate`/`classify`/`embed`/etc. are macros invoked from inside a consumer's own arbitrary
model files, not standalone models, so a per-model `+enabled`/materialization gate under
`models:` does not apply here. A package's hooks are not inherited by projects that install it,
either: declaring `on-run-start`/`on-run-end` in this package's own `dbt_project.yml` has no
effect on a consuming project. Only that project's own hooks run.

## Decision

**AI functions are off by default, and the audit log they can write to bootstraps once, serially,
before any threaded model execution.**

`ai_functions_enabled` (`dbt_project.yml`, default `false`). `require_ai_functions_enabled(fn_name)`
raises a compiler error when it is not set, gated on `execute`:

```jinja
{% macro require_ai_functions_enabled(fn_name) -%}
    {%- if execute and not var('ai_functions_enabled', false) -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): AI functions are disabled by default. Set var ai_functions_enabled: "
            ~ "true for this target to allow a real AI call to fire."
        ) }}
    {%- endif -%}
{%- endmacro %}
```

Called as the first statement inside `generate`, `classify`, `extract`, `embed`, and `ai_agg`'s
own outer macro, before `adapter.dispatch`, so calling any of them unavoidably runs it.

`log_ai_run` no longer self-creates `ai_run_log`. `create_ai_run_log_table()` ships for a
consumer's own `on-run-start` hook instead:

```yaml
# dbt_project.yml
on-run-start:
  - "-- depends_on: {{ ref('ai_run_log') }}\n{{ dbt_context_engineering.create_ai_run_log_table() }}"
```

```jinja
{% macro create_ai_run_log_table() -%}
    {%- if var('ai_functions_enabled', false) and execute -%}
        {%- do run_query(
            "create table if not exists " ~ ref('ai_run_log') ~ " as (" ~ dbt_context_engineering.ai_run_log_columns_sql() ~ ")"
        ) -%}
    {%- endif -%}
    {{ return('select 1') }}
{%- endmacro %}
```

If `ai_run_log` is not selected and no `on-run-start` hook is wired, `log_ai_run`'s `INSERT` fails
with the engine's own "table does not exist" error, naming the table directly. That is
intentional.

The `-- depends_on:` comment is required. `ref()` inside the macro's conditional block is not
statically inferable by dbt's parser without it; omitting it produces a compile error naming the
exact fix.

## Reasoning

**Why the check has to live inside the function, not in a value a caller supplies.** As established
above: a wrapper in a config value is bypassed by writing a literal instead, which is the
easier path, not a deliberate one. Putting the check inside `generate`/`classify`/`embed`/etc.
themselves means calling the function is what triggers the check, not choosing to call a second,
separate helper.

**Why `execute` gating is not an edge case to patch around, but a required property of any check
placed here.** Any `raise_compiler_error` inside a macro shared across five functions will, absent
this gate, fire during manifest parsing for every model that calls any of them, project-wide,
regardless of selection. This is not specific to `ai_functions_enabled`; it would break the same
way for any unconditional check placed at this injection point.

**Why the missing-table case gets no custom error message.** The engine's own error already names
the exact missing table on every engine (confirmed: Snowflake, BigQuery, Databricks, duckdb all
name `ai_run_log` directly). A wrapper would only add "why" and "what to do," which belongs in
documentation a maintainer reads, not a runtime check that adds a metadata query to every hook
invocation to produce a marginally better message.

**Why `on-run-start`, not a smarter self-create.** `CREATE TABLE IF NOT EXISTS` is logically
idempotent, but BigQuery's rate limit counts the attempt itself, not the logical outcome; no
amount of "check first" in application code changes that once multiple models attempt it in the
same narrow window. `on-run-start` hooks run once, serially, before any node begins executing,
confirmed directly: in a live run, the hook's own `START`/`OK` lines complete in full before any
of eight concurrently-scheduled models' `START` lines appear. There is no other writer to race
against, because nothing else has started yet.

**Why `create_ai_run_log_table` also checks `ai_functions_enabled`, for a different reason than
`require_ai_functions_enabled` does.** The dispatch-layer check is about safety: stopping a real,
billed call. This check is about efficiency: skipping a bootstrap that a project which never
enables AI functions never needed in the first place. It is not a second safety mechanism, and
removing it would still be correct, only wasteful on a purely structural run.

**Why this cannot ship as a hook inside the package's own `dbt_project.yml`.** A package's hooks
are not inherited by projects that depend on it; only the consuming project's own hooks run.

## Consequences

- **A consumer must explicitly select `ai_run_log` or wire `create_ai_run_log_table` via their own
  `on-run-start`, or get a clear, engine-native error instead of automatic lazy creation.** This is
  a real behavior change from the removed `ensure_ai_run_log_exists()`, traded deliberately: the
  self-create was exactly what raced.
- **Every AI-calling model, in every project that depends on this package, now requires
  `ai_functions_enabled: true` to run at all, including this package's own integration test
  fixtures that call real AI functions.** Confirmed live on Snowflake: a plain, unrestricted
  `dbt build` with the var unset blocked every AI-calling model individually with an actionable
  error while 78 unrelated, zero-cost models still built and tested clean.
- **This record does not resolve `complete_ai_run`'s `UPDATE` conflict.** That root cause
  (confirmed live, 7 of 8 models failing on Databricks against a table that already existed) is
  unaffected by anything decided here. Resolved separately: see
  [ADR-0031](0031-run-completion-as-an-event-sourced-append.md), which replaces the `UPDATE` with
  a second `INSERT`.
- **View-safety (rejecting `materialized='view'` on an AI-calling model) is built.**
  `require_safe_materialization(fn_name)` uses the same dispatch-layer injection point
  `require_ai_functions_enabled` uses, checking `config.get('materialized')` instead of
  `ai_functions_enabled`, and is wired into all five AI functions alongside it.
- **`ADR-0021` documents the removed self-create behavior as an accepted decision.** Superseded:
  [ADR-0021](0021-run-completion-as-a-boolean-set-by-its-own-post-hook.md)'s Status now points to
  ADR-0031.
- **Full-refresh gating is built, using the same dispatch-layer pattern.**
  `require_full_refresh_gate(fn_name)` raises when an AI-calling model is
  `materialized='incremental'` with no explicit `full_refresh` config. Like every other
  config-value check in this package, it does not care WHICH value was chosen, only that dbt's
  implicit default (a bare `--full-refresh` always fully reprocesses) isn't left silently unset; a
  model author who hardcodes `full_refresh=true` satisfies the gate while reintroducing the exact
  exposure it exists to close. The recommended value, `full_refresh=var('allow_full_reembed',
  false)`, is what actually makes a reprocess require an explicit opt-in at invocation time; that
  property comes from the convention, not from anything the gate itself can enforce. In
  `macros/functions/require_prerequisites.sql`; see `README.md`'s Configuration section for the
  var.
- **Dev-mode row sampling is built.** `dev_sample_filter(row_limit=none)` caps a model to a random
  `row_limit` (or `var('ai_sample_rows')`) rows via `qualify row_number() ... <= n`, for iterating
  against a small slice before running the full batch. In `macros/cost/dev_sample_filter.sql`; see
  `README.md`'s Configuration section for the var.

## Alternatives considered

- **A caller-supplied macro that validates and returns a config value** (e.g.
  `config(materialized=validated_materialization(...))`). Rejected. It only fires if a model
  author routes their value through it; writing the value directly bypasses it entirely, and
  skipping it is the easier path, not a deliberate one.
- **A custom, friendlier error when `ai_run_log` is missing.** Rejected. The engine's own error
  already names the table precisely on every engine; a wrapper adds a runtime metadata check for
  marginal benefit over what already exists.
- **Serializing every build (`--threads 1`).** Rejected as a real fix, though usable as a manual,
  occasional workaround: it discards the concurrency dbt would otherwise give independent models,
  and cannot help an unattended scheduled job that cannot notice a failure and retry with lower
  concurrency after the fact.
- **Retry-with-backoff around the write statements.** Rejected as infeasible. Jinja templates have
  no exception handling; a macro cannot catch a database error raised by `run_query()` and retry
  within pure macro code.

## Glossary

- **`on-run-start` / `on-run-end`**: dbt hooks that run once, serially, strictly before or after
  all node execution for an invocation, never concurrently with model builds.
- **`execute`**: a Jinja context flag, `false` during dbt's parse phase (which renders every
  model's Jinja to build the manifest, regardless of `--select`) and `true` during the run phase
  (which only re-renders models actually selected this invocation).
- **Optimistic concurrency control**: a concurrency strategy (used by Delta Lake) where a
  transaction reads a version, does its work, and fails at commit time if another transaction
  committed a newer version first, rather than locking upfront. `DELTA_CONCURRENT_APPEND` is that
  failure surfacing.
- **Dispatch-layer check**: a check placed inside a macro's own body, before it dispatches to a
  per-adapter implementation, so every caller runs it unconditionally, as opposed to a check a
  caller must separately choose to invoke.

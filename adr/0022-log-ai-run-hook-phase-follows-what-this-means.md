# 22. `log_ai_run`'s hook phase follows what `this` means to the call

## Status

Accepted, 2026-08-12.

## Concept

`pre_hook` and `post_hook` see `this` in genuinely different states: `pre_hook` runs before the
model's own create or merge statement, `post_hook` runs after. A macro that measures "how many
rows did this run touch" gets a different answer, sometimes silently wrong, depending on which
side of that boundary it runs on. `log_ai_run` can reach `this` two different ways, through its
`relation` argument (defaulted to `this`) and through its `filter` argument (when derived from
`this`, as `incremental_delta_predicate` is), and those two paths need **opposite** hook phases
to be correct.

## Context

dbt enforces no guardrail here; nothing stops a hook from referencing `this` in the wrong phase,
and the wrong phase does not always error, it can just silently produce the wrong number.

[PR #9](https://github.com/dbt-labs/dbt-context-engineering/pull/9) found the first half of this
the hard way: the README's canonical "Governed incremental AI model" pattern (ADR-0003) had
`guard_batch` as a pre-hook and `log_ai_run` as a post-hook, both scoped by
`incremental_delta_predicate` (which expands to `<unique_key> not in (select <unique_key> from
{{ this }})`). That predicate is only correct pre-merge. By the time a post-hook fires, the run's
merge has already landed the new rows into `this`, so the same predicate finds nothing and logs
`row_count = 0` for a run that actually processed rows. This was found in a real downstream
consumer, `dbt_gong`'s AI-powered transcript context layer, following the documented pattern
exactly as written, not a hypothetical.

The second half surfaced while extending that fix: `log_ai_run`'s `relation` argument defaults to
`this` (sizing the model's own output, no `filter`), and that path needs the opposite phase from
the one PR #9 fixed.

## Decision

**Hook phase is dictated by what `relation`/`filter` reference, not a free choice.** Three cases:

1. `relation` is an explicit `ref()` to some OTHER table, and `filter` (if any) doesn't reference
   `this`. Either `pre_hook` or `post_hook` works; that other table's state doesn't depend on
   THIS model's build.
2. `relation` left at its default (`this`), sizing from the model's OWN output, no `filter`.
   Requires `post_hook`. `pre_hook` runs before the create/merge, so `this` doesn't exist yet on
   a first build and holds last run's stale state on later builds either way. Only sound on a
   `table` (or otherwise always-fully-rebuilt) materialization, where "the freshly built output"
   and "this run's batch" are the same thing.
3. `filter` derived from `this` (e.g. `incremental_delta_predicate`), the delta-scoping pattern on
   an incremental model. Requires `pre_hook`, the case PR #9 fixed.

Never combine case 2 with an incremental model tracking a genuine per-run delta. Unfiltered
`relation=this` on an incremental model is wrong in both phases, not a hook-phase choice at all:
`pre_hook` reports last run's state, missing this run's rows entirely; `post_hook` reports the
whole cumulative table, every row ever merged in, not this run's batch.

## Reasoning

**Why case 3 needs `pre_hook`.** The predicate's entire meaning, "not yet in the target," is only
true before the merge runs. Confirmed twice: once in production (PR #9, `dbt_gong`), and again by
deliberately reintroducing the post-hook pattern in a reproduction of the exact `logged_delta`
scenario, watching the real 5-row delta build log `row_count = 0` instead of 5.

**Why case 2 needs `post_hook`.** Confirmed by deliberately putting `log_ai_run`'s default
`relation=this` on a `pre_hook`: it errored outright on a fresh build, `Catalog Error: Table ...
does not exist!`, since `pre_hook` runs before the create statement ever executes.

**Why cases 2 and 3 look symmetric but aren't in tension.** They answer different questions. Case
2 asks "what did this model's build ultimately produce," which only has an answer after the
build finishes. Case 3 asks "which rows are new this run," which only has an answer before the
merge folds them in. Only case 3's question has a sane answer on an incremental model; case 2's
question doesn't even make sense there; unfiltered `relation=this` on an incremental model just
grows without bound, run over run, regardless of hook phase.

## Consequences

- `log_ai_run`'s docstring and the README's "Governed incremental AI model" section state the
  three cases explicitly, replacing the earlier "safe as either, watch this one warning" framing
  that case 3 alone left in place after PR #9.
- Case 3 is backed by a permanent regression test, `logged_delta` / `assert_logged_delta`
  (duckdb), which exercises a genuine two-build incremental delta and fails with `row_count = 0`
  if the post-hook pattern regresses (confirmed by temporarily reintroducing it).
- Extends ADR-0003 (guard as pre-hook, log as post-hook, in general) without changing its core
  decision; this narrows exactly when that general pattern flips.

## Alternatives considered

- **Always `pre_hook`**: rejected. Breaks case 2; `log_ai_run`'s default `relation=this` errors
  on a fresh build when run as a `pre_hook`, since the table doesn't exist yet at that point.
- **Always `post_hook`**: rejected. Breaks case 3, the exact failure PR #9 found in production;
  the delta predicate finds nothing once the merge has already run, logging `row_count = 0` for a
  run that really processed rows.

## Glossary

- **`this`**: the dbt `Relation` for the model currently being built. Resolves to the same
  identifier in `pre_hook` and `post_hook`, but the physical table behind it is in a different
  state in each: nonexistent or last-run's-old before the build, freshly built or merged after.
- **Pre_hook / post_hook**: SQL dbt runs immediately before, or after, building a model. A
  `pre_hook` runs before the create/merge statement; a `post_hook` runs after it, inside the
  model's own transaction.
- **`incremental_delta_predicate`**: the macro that returns `<unique_key> not in (select
  <unique_key> from {{ this }})`, or `none` on a first build/full-refresh. Only correct read
  before the current run's merge has landed new rows into `this`.
- **Delta**: the subset of rows an incremental model's run actually processes this time, as
  opposed to the whole corpus already sitting in the target table.

# 28. Add `ai_agg`: a fifth operation for group-level LLM aggregation

## Status

Accepted, 2026-08-23.

## Concept

[ADR-0010](0010-four-ai-operations.md) named four AI operations, each a row-level call that returns
a value dropped into a `SELECT`. `ai_agg` is a fifth: the same shape, a value the caller drops into
its own query, except its grain is a `GROUP BY` group rather than a single row. It mirrors
Snowflake's `AI_AGG` and BigQuery's `AI.AGG`, asking a model to reason across every row in a group
at once (summarize a call transcript, roll up sentiment for an account) instead of row by row.
Databricks has no native equivalent, so its path is a composition built from primitives this
package already has, not a new native call.

## Context

Snowflake's `AI_AGG(expr, instruction)` and BigQuery's `AI.AGG(...)` were confirmed live 2026-08-23
against a two-group, ten-row fixture. Three things diverge enough between engines to matter for the
decision below:

- **Model control.** `AI_AGG` takes no model argument, Snowflake picks internally. `AI.AGG` does
  take an `endpoint` argument (its live signature is positional,
  `AI.AGG(T1, T2, [connection_id], [endpoint], ...)`, not the commonly documented named
  `instructions =>` form).
- **Row order.** Confirmed via a verbatim-quote probe (ask the aggregate to quote the transcript's
  last line exactly, compare a naturally-ordered feed against a reverse-sorted one), repeated three
  times for BigQuery to rule out stochastic noise. Snowflake's `AI_AGG` honors an `ORDER BY` placed
  ahead of its `GROUP BY`. BigQuery's `AI.AGG` does not, identical output regardless of input order
  across all three trials.
- **Oversized input.** Both native functions handle a group exceeding the model's context window
  with an internal map-reduce. Databricks has no equivalent primitive at all, so the composition
  built for it (a standard SQL aggregate to collapse the group, piped through `ai_query`) has no
  such protection.

Collapsing a group on Databricks also needed its own fix: `collect_list`/`array_agg` support
neither `array_agg(x order by y)` nor `... within group (order by y)` (both fail to compile), so a
deterministic order needs `sort_array(collect_list(struct(order_col, text_col)))` instead.

## Decision

**Ship `ai_agg(input_column, prompt, order_column=none, model=none)` as a fifth operation,
dispatched per engine like the other four.** Databricks' path is a bounded composition, not an
attempt to reproduce map-reduce: collapse the group (`array_agg`/`array_join`, or the
`sort_array`/`struct`/`transform` pattern when `order_column` is given), pipe it through `ai_query`,
and require a per-group token ceiling checked before that call runs (`guard_agg_batch`, a grouped
variant of `guard_batch`), so an oversized group fails the build loudly instead of risking a silent
truncation. Full per-engine behavior, which arguments are honored where, is documented in the
macro's own docstring (`macros/functions/ai_agg.sql`) and the README, not repeated here.

```sql
{{ config(
  pre_hook = "{{ dbt_context_engineering.guard_agg_batch(ref('utterances'), 'utterance_text', 'call_id') }}"
) }}
select
  call_id,
  {{ dbt_context_engineering.ai_agg('utterance_text',
      'Summarize this call in one sentence.', order_column='turn_index') }} as call_summary
from {{ ref('utterances') }}
group by call_id
```

## Reasoning

**Why bound rather than reproduce map-reduce.** A real equivalent, pre-chunk an oversized group
with `chunk()`, generate per chunk, reduce the partial results, is real, achievable work, but it
would make Databricks' `ai_agg` own intermediate row grain (a chunk-per-group table, a
partial-summary-per-chunk step) while Snowflake's and BigQuery's stay a single expression. Shipping
the bounded version now keeps `ai_agg` the same shape on every engine; the map-reduce alternative is
deferred, not rejected, see below.

**Why the ceiling reuses `guard_batch`'s shape.** `guard_batch` already runs a query at execute
time and raises when a count or token-sum exceeds a `var`-driven threshold. A per-group ceiling is
that same mechanism with `GROUP BY` added, no new class of guard needed to exist for this to be
safe.

## Consequences

- **Cross-adapter behavior genuinely diverges for oversized groups.** Databricks fails the build
  at the ceiling; Snowflake and BigQuery absorb it transparently via their own internal map-reduce.
- **`model=` is a no-op on Snowflake only.** `AI_AGG` exposes no model selection at all; both
  Databricks (`ai_query`) and BigQuery (`AI.AGG`'s `endpoint` argument) honor it.
- **`order_column` is a no-op on BigQuery** (confirmed order-insensitive across three trials), and
  on Snowflake only takes effect if the caller also pre-sorts their own `FROM` clause, this macro
  returns a single expression and cannot alter the caller's `FROM` clause itself.
- **The ceiling default (`max_agg_group_tokens`) is tied to whatever model `ai_agg` is pointed
  at**; changing the model requires revisiting it.
- Related: [ADR-0010](0010-four-ai-operations.md) (the four operations this extends),
  [ADR-0003](0003-cost-as-a-first-class-output.md) (`guard_batch`, reused here in grouped form).

## Alternatives considered

**A real map-reduce equivalent on Databricks** (pre-chunk an oversized group with `chunk()`,
generate per chunk, reduce the partial summaries) would get true behavioral parity with
Snowflake/BigQuery for arbitrarily large groups. Deferred, not rejected: it is separate
engineering, not a macro change, it would make Databricks' `ai_agg` own row grain while the other
two engines' stay a single expression, and the reduce step's own information-loss risk hasn't been
evaluated. Worth building if the bounded ceiling proves to bite often enough in practice; earns its
own ADR at that point rather than amending this one.

## Glossary

- **Map-reduce** (in this context): an LLM provider's internal strategy for handling input larger
  than one context window, splitting it into pieces, summarizing each, then combining those partial
  results, transparent to the caller. Snowflake's `AI_AGG` and BigQuery's `AI.AGG` both do this;
  nothing on Databricks does it automatically.
- **Token ceiling**: a `var`-driven upper bound on a group's estimated token count, checked before
  an AI call runs, so an oversized group fails the build loudly instead of silently reaching a model
  that will error or truncate on it.

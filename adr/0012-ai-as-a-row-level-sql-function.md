# 12. AI as a row-level SQL function (prompt → column)

## Status

Accepted.

## Concept

The mental leap that makes this whole package click, especially for someone coming from dbt: **an
LLM call is just a column expression.** You do not export rows to a Python service, loop over an API,
and stitch the results back. You call the model *from SQL*, one row at a time, and the answer is a
new column in a table that dbt materializes like any other model.

```sql
select
  id,
  {{ dbt_context_engineering.ce_generate('body', p) }} as summary   -- a model call, as a column
from {{ ref('docs') }}
```

How does a prompt become SQL? The versioned prompt is a template with an `{{ input }}` placeholder;
rendering replaces that placeholder with the *column reference*, producing a portable string
expression like `'Summarize:\n' || body`, which the wrapper hands to the engine's native AI function.
So "apply this prompt to every row" is, literally, a `SELECT`. Run the model and you have an enriched
table sitting in the DAG next to everything else.

The thesis in one line: **enrichment runs where the data already lives**, governed by the same DAG,
tests, and lineage as every other model, with no data movement and no separate service to operate.

## Context

The instinct most teams bring is the *integration* pattern: pull rows into a notebook or a Python
job, call an API in a loop, write results back. It works, but it drags the AI step *outside* the
warehouse's governance, it's untested, unversioned, un-lineaged, and it moves potentially sensitive data
out of the boundary. Warehouses now expose AI as first-class SQL functions, which makes a different
pattern possible: keep the model call *inside* SQL.

## Decision

Every enrichment is a **row-level SQL expression**. `ce_render_prompt` turns a resolved prompt plus
an input column into a portable concatenation; the wrappers wrap that in the engine's native AI
function; the result is a column. AI models are therefore *ordinary dbt models*, incremental,
tested, and decorated with the cost guard and run-log hooks, not scripts living beside the project.

```sql
{{ config(materialized='incremental', unique_key='id',
          pre_hook="{{ dbt_context_engineering.ce_guard_batch(ref('docs'), 'body') }}") }}
select id, {{ dbt_context_engineering.ce_classify('body', p, s) }} as signal
from {{ ref('docs') }}
```

## Reasoning

**Why in-warehouse, row-level inference instead of an external batch job.** Two reasons, and the
whole package rests on them. First, *governance*: expressed as a model, the AI step inherits
everything dbt already gives every other transform — version control, code review, tests, lineage,
scheduling, and the DAG. Pull it into a notebook and you lose all of that for the single most
error-prone step in the pipeline. Second, *data gravity*: calling the model from SQL means the data
never leaves the warehouse boundary — no export, no egress, no second copy to secure. Inference comes
to the data, not the reverse.

**Why per-row (a column) rather than one giant prompt over the whole table.** Stuffing many rows into
one prompt seems cheaper, but it breaks almost everything that matters. Per-row keeps a clean 1:1
between input and output (so lineage survives — see
[ADR-0011](0011-lineage-and-citations-as-a-first-class-invariant.md)); it composes with incremental
builds (only new rows are processed) and with per-run cost guards and logs
(see [ADR-0003](0003-cost-as-a-first-class-output.md)); and it sidesteps the context window, which a
whole-table prompt would blow. A column is the unit that composes with the rest of dbt.

**Why the render / `{{ input }}` step exists.** It's the seam that makes a *versioned* prompt
(see [ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md)) reusable across any input column
and any engine: rendering produces a plain, portable string concatenation that every dialect
understands, with the row's text spliced in. Without it, a prompt would be welded to one column name.

The craft lesson: **treat inference as a transformation, not an integration.** The moment AI is "just
another column," it stops being a special, ungoverned side-system and becomes a first-class,
testable, lineage-carrying step in the pipeline.

## Consequences

- Enrichment is an ordinary dbt model — versioned, tested, in the DAG, with no external service to
  build or operate, and no data leaving the warehouse.
- Because it's per-row, it composes cleanly with the cost guard and run log
  ([ADR-0003](0003-cost-as-a-first-class-output.md)), version-aware refresh
  ([ADR-0004](0004-version-aware-incremental-refresh.md)), and lineage
  ([ADR-0011](0011-lineage-and-citations-as-a-first-class-invariant.md)).
- Cost scales with the number of rows, which is exactly *why* the guard exists — an unbounded table
  is an unbounded bill.
- The model's *return shape* still differs per engine; that's handled downstream by the output
  accessors ([ADR-0008](0008-normalizing-ai-output.md)).

## Glossary

- **Row-level inference** — running the model once per row, as a column expression, rather than once
  over a whole table or in an external batch.
- **Column expression** — a SQL fragment that computes a value for each row (here, the AI call);
  dropping it in a `SELECT` produces a new column.
- **Prompt rendering / `{{ input }}`** — replacing the prompt template's placeholder with the input
  column reference, yielding a portable string like `'…' || body` that the AI function consumes.
- **Native AI SQL function** — the warehouse's built-in function that actually calls the model
  (e.g. `AI_COMPLETE`); the wrappers turn a rendered prompt into a call to it.
- **In-warehouse AI / data gravity** — running inference where the data already sits, so nothing is
  exported; the model comes to the data.
- **Data movement (egress)** — copying data out of the warehouse to another system (e.g. a Python
  service). The row-level-SQL approach avoids it, keeping data inside the governed boundary.
- **DAG** — dbt's dependency graph; because AI steps are models, they live in it and inherit its
  ordering, tests, and lineage.

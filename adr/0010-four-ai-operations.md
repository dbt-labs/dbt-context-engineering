# 10. Four AI operations: generate, classify, extract, embed

## Status

Accepted, 2026-07-30.

## Concept

Context engineering runs on a surprisingly small vocabulary of things you actually ask a model to do
to a row of text. This package names **four**, and between them they cover the large majority of
enrichment work:

- **generate** — produce free-form text from the input (a summary, a rewrite, an answer).
- **classify** — choose exactly *one* label from a fixed set (a taxonomy).
- **extract** — pull *structured fields* out of the text into a typed record.
- **embed** — turn the text into a *vector* for semantic search.

They look interchangeable, each is "call a model on a column", but they differ in **output shape**
and **intent**, and choosing the right one is most of the skill:

| | returns | schema | typical use |
|---|---|---|---|
| `generate` | free text, or a structured object | optional | summarize, rewrite, answer, bespoke JSON |
| `classify` | one **scalar label** | required (its `enum` = the labels) | bucket a row into a taxonomy |
| `extract` | a **typed record** (many fields) | required (the contract) | pull facts *present in the text*, with an evidence quote |
| `embed` | a **vector** | none (a pinned model) | make text searchable by meaning |

The quickest way to keep them straight: **classify** gives you *the bucket*, **extract** gives you
*the fields (plus a quote you can verify)*, **generate** gives you *whatever you describe*, and
**embed** gives you *the coordinates for search*.

## Context

Every target warehouse exposes AI as SQL functions, but with a different name and surface per
operation *and* per engine (Snowflake `AI_CLASSIFY`, Databricks `ai_classify`, BigQuery
`AI.GENERATE`, and so on). Left alone, a practitioner learns several native signatures per warehouse
and rewrites them when they change engines. We wanted one authoring surface: a few clear verbs, each
dispatching to the right native function.

## Decision

Ship exactly four wrappers — `ce_generate`, `ce_classify`, `ce_extract`, `ce_embed` — each a
row-level call (see [ADR-0012](0012-ai-as-a-row-level-sql-function.md)) that returns a value you drop
into a `SELECT`. Each maps to the engine's native function:

| operation | Snowflake | Databricks | BigQuery |
|---|---|---|---|
| generate | `AI_COMPLETE` | `ai_query` | `AI.GENERATE` |
| classify | `AI_CLASSIFY` | `ai_classify` | `AI.GENERATE` (enum in the prompt) |
| extract | `AI_EXTRACT` | `ai_query` | `AI.GENERATE` |
| embed | `AI_EMBED` | serving endpoint | `AI.EMBED` |

`classify` and `extract` require a schema (its `enum`/fields are the contract); `generate`'s schema
is optional; `embed` takes no prompt, only a pinned model.

```sql
select
  {{ dbt_context_engineering.ce_classify('segment', p, s) }}  as signal,   -- one label
  {{ dbt_context_engineering.ce_embed('segment') }}           as embedding  -- a vector
from {{ ref('segments') }}
```

## Reasoning

**Why four operations and not one general `generate`.** You *could* express classify and extract as
"generate, but return JSON like this." Collapsing them, though, throws away portability and safety.
`classify` can use a dedicated native function that is cheaper and enum-constrained; `extract` maps
to purpose-built typed-extraction functions; `embed` is a different *modality* entirely (it emits
vectors, not text). Fold everything into `generate` and every user re-invents enum enforcement, field
parsing, and vector handling by hand. Naming the operations is what lets the package do that work
once, per engine, behind each verb.

**Why classify and extract are distinct even though both take a schema.** Intent. `classify` answers
"which bucket?" and returns a single scalar label; `extract` answers "what facts are *in* this text?"
and returns several fields, including a verbatim evidence quote. Different questions, often different
native functions, and different downstream handling (a scalar vs. a record to flatten).

**Why `generate` is the escape hatch.** Not everything is a bucket, a field set, or a vector.
Summaries, rewrites, and open answers need free text; `generate` is the general tool, used
deliberately rather than as the default for tasks the other three do better.

**Why `embed` stands apart.** It's the read-side enabler. It produces the vectors that retrieval and
knowledge bases search, so it has no prompt, a pinned model, and its own comparability rules
(see [ADR-0004](0004-version-aware-incremental-refresh.md)).

The lesson: **name the small set of operations explicitly.** A good vocabulary is half the
design; it tells the user what's possible and lets the implementation optimize each case.

## Consequences

- One surface, four verbs; the correct native function fires per engine, so a pattern written once
  runs on all three.
- `classify`/`extract` carry the taxonomy/contract; their per-engine return shapes are normalized by
  the output accessors (see [ADR-0008](0008-normalizing-ai-output.md)).
- Each verb is an AI call, so each is shipped with a cost guard and run-log available
  (see [ADR-0003](0003-cost-as-a-first-class-output.md)).
- `embed` feeds retrieval (see [ADR-0005](0005-retrieval-brute-force-default-index-opt-in.md)); the
  other three produce columns you filter, join, and test.

## Glossary

- **Generate / classify / extract / embed** — the four AI operations above: free text; one label; a
  typed record; a vector.
- **Taxonomy / label set** — the fixed set of categories `classify` may return, declared as the
  schema's `enum`.
- **Structured vs. free-form output** — free-form is a paragraph; structured is data in a declared
  shape (fields/types). `classify` and `extract` are structured; `generate` can be either.
- **Modality** — the *kind* of thing produced. Text (generate/classify/extract) and vectors (embed)
  are different modalities, which is why embed is handled separately.
- **Vector / embedding** — a list of numbers encoding meaning, so similar texts are near each other;
  what `embed` produces and retrieval searches.
- **Native AI function** — the warehouse's built-in SQL function (e.g. `AI_CLASSIFY`) that a wrapper
  dispatches to; the package's verbs are a thin, portable layer over these.

# 36. Add `decide`: a sixth operation for decision models

## Status

Accepted, 2026-10-20.

## Concept

A **decision model** answers typed questions about a piece of text and never writes prose. Ask it
"which of these four topics is this about?" and it returns the topic, a **probability** for every
topic, and a **confidence** in its answer. Ask "is the speaker frustrated?" and it returns the
probability that the statement is true. Ask "how negative is the tone, on this three-level
rubric?" and it returns a probability-weighted position on the rubric.

That is different in kind from asking a generative model to classify. `classify` returns a label
and nothing else ([ADR-0008](0008-normalizing-ai-output.md)), so a clear call and a coin flip look
the same. A decision model's confidence lets a pipeline treat them differently, for example by
sending uncertain rows to a person instead of filtering on them as if they were certain.

[ADR-0010](0010-four-ai-operations.md) named four row-level operations and
[ADR-0028](0028-add-ai-agg-group-level-aggregation.md) added a fifth. This record adds a sixth,
`decide`, for decision models.

## Context

Three question types are common to every decision-model interface we found: **choice** (one label
from a described set), **noul** (the probability a statement is true) and **score** (a position on
an ordered rubric). Engine support, researched 2026-10-20:

| Engine | Path | Row-level SQL expression | Status |
|---|---|---|---|
| Databricks | `ai_decide(state, questions[, options])` | Yes | Beta, region-limited, not on SQL Classic |
| Snowflake | `AI_COMPLETE(model => 'snowflake-decision', prompt => TO_JSON({state, questions}))` | Yes | Private preview since 2026-10-07 |
| BigQuery | None. `AI.CLASSIFY` takes label descriptions and returns the label only | No | |

Databricks' `questions` argument must be a constant: the same question definitions for every row.
A choice question allows 1 to 255 labels on Databricks; Snowflake's announcement cites 32.

A live `ai_decide` call on Databricks, one choice and one noul question over one ticket, returned:

```json
{"error_message": null,
 "metadata": {"version": "1.0"},
 "response": {"answers": {
   "dept": {"choice": "technical", "confidence": 0.95,
            "probabilities": {"billing": 0, "sales": 0, "technical": 1}, "type": "choice"},
   "urgent": {"probability": 0.9, "type": "noul"}}}}
```

The result names no model. `metadata.version` is the `ai_decide` function version, and Databricks
documents that the underlying model may change. Snowflake's documented result is an `answers`
object without that envelope, and its noul answer names the probability `noul` rather than
`probability`.

Our Snowflake account returned, with the package's Snowflake path enabled, on dbt Core and Fusion
alike:

```
The model you requested is unavailable in your region. To access it, enable cross region
inference with ANY_REGION.
```

The statement compiled and reached the model check, so the SQL shape is accepted. No answer has
been returned to us.

Neither engine publishes how its decision model is billed. Databricks' announcement says only
that `ai_decide` is "faster and lower cost than LLMs on similar tasks", with no figures, and names
no billing unit; Snowflake Decision's pricing is not public. The published per-token prices we
found describe TypeSafe's hosted Jev and a self-hosted model on Snowpark Container Services, not
either native function.

A third-party package, Jevflake, exposes TypeSafe's Jev on Snowflake through a Python UDF that calls
TypeSafe's HTTP API. Row content leaves the warehouse on that path.

## Decision

**We will add `decide(state_column, questions)`, a row-level operation over native warehouse
decision models, that returns the engine's raw result, read through `decide_answer` and
`decide_error`, with engine support decided in one place, `decide_available()`.**

- `macros/functions/decide.sql`. The outer macro runs `require_ai_functions_enabled`,
  `require_safe_materialization` and `require_full_refresh_gate`, validates the questions, checks
  `decide_available()`, then dispatches.
- `questions` is a compile-time dict keyed by question id. `validate_decide_questions` rejects, at
  execute time: a non-dict or empty set; an id that is not an identifier; a field other than
  `type`, `instructions` and `criteria`; a type other than `noul`, `choice`, `score`; empty
  instructions; a choice without a label-to-description mapping or over the engine's cap; a score
  without 2 to 10 levels; noul criteria with keys other than `true` and `false`; a choice label or
  description, score level or noul description that is not a non-empty string; a repeated score
  level.
- `decide_questions_json(questions)` serializes the questions as JSON text in declared order:
  question ids as given, each question's fields as `type`, `instructions`, `criteria`, and choice
  labels as given. Scalars and lists go through `tojson`. Both engine paths send it, and hooks size
  `decide` with `log_ai_run('decide', ..., prompt=decide_questions_json(questions))`.
- The choice cap is `var('decide_choice_cap_databricks', 255)` and
  `var('decide_choice_cap_snowflake', 32)`, the engines' documented limits, raisable if an engine
  raises its own. No lower soft threshold is applied.
- `decide_available()` is true on Databricks, true on Snowflake only when
  `var('decide_snowflake_preview')` is true (compared as normalized text), and false everywhere
  else.
- Where it is false, `decide()` raises at execute time: the platform does not yet offer a decision
  model this package can call; use `classify()`, which labels from the same fixed set without a
  confidence. On Snowflake the message adds that an account with preview access can opt in with
  `decide_snowflake_preview: true`.
- `databricks__decide` is `ai_decide(<state>, '<decide_questions_json>')`.
- `snowflake__decide` is `parse_json(to_varchar(ai_complete(model => 'snowflake-decision',
  prompt => '{"state": ' || to_json(to_variant(<state>)) || ', "questions": ' ||
  '<decide_questions_json>' || '}')))`, assembled as text because a Snowflake OBJECT does not keep
  key order, and marked LIVE-VALIDATION DEFERRED in the macro.
- `decide_answer(decision, question, field, as_type)` reads `choice`, `confidence`,
  `probabilities`, `probabilities.<label>`, `score`, `legend` and `probability`, cast to `as_type`.
  The Databricks branch reads `response.answers.<question>.<field>`; the Snowflake branch reads
  `answers.<question>.<field>` and maps `probability` to `noul`; the default branch reads the
  Databricks envelope from a JSON string, which is what the duckdb tier seeds.
- `decide_error(decision)` returns Databricks' `error_message`. Snowflake reports a failed call as
  a query error, so its branch returns null.
- `decide_model(decision)` returns `ai_decide/<metadata.version>` on Databricks and
  `snowflake-decision` on Snowflake.
- `log_ai_run('decide', ..., prompt=decide_questions_json(questions))` counts the questions JSON on every row and
  defaults the output allowance to 0, because a decision model returns typed answers, not
  generated text. With no published billing unit, `decide`'s `est_tokens` and `est_cost` measure
  request size under the project's per-token price, not a bill, and this record makes no cost
  comparison between `decide` and `classify`. Logging `decide` with no `prompt` warns, naming the
  model.
- The questions are defined in a macro in the calling project and called from the body,
  `guard_batch` and `log_ai_run`, so all three share one definition. There is no meta entry for
  `decide`.

```sql
select
    utterance_id,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'choice') }} as topic,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'confidence', dbt.type_float()) }} as confidence
from {{ ref('decided') }}   -- decided.d = decide('utterance_text', questions)
```

## Reasoning

**Why a new operation rather than a decision-model backend behind `classify`.** `classify` returns
a scalar label by contract (ADR-0008), and `knowledge_base.classification` depends on that
([ADR-0027](0027-classification-as-a-second-privileged-knowledge-base-column.md)). A decision model
behind it could not return confidence without breaking the contract, and would change existing
users' labels without their asking.

**Why return the raw result and normalize on read.** A row-level expression cannot reference its
own result twice. Building a normalized object inside `decide` would call `ai_decide` once per
field extracted, each call billed. Storing the raw result and reading fields with `decide_answer`
calls the model once per row, the same split `extract` and `field` already use.

**Why `decide_available()` instead of per-engine dispatch alone.** The vocabulary pipeline
([ADR-0037](0037-fixed-vocabulary-classification-with-confidence-routing.md)) has to know before
compiling whether `decide` will run, to choose its method. One macro answers that for `decide`
and everything built on it, so the two cannot disagree.

**Why Snowflake is written but disabled.** The path is built from Snowflake's announcement, and
the full syntax sits behind a limited-access page. Our account cannot reach the model. Enabled by
default, a field-name or envelope mismatch would surface as nulls in a green build. Disabled, no
one runs it by accident, and an account with preview access opts in knowingly.

**Why the caps are the engines' documented limits and nothing lower.** TypeSafe reports Jev's
choice as reliable to about 240 labels. That figure describes a different implementation, and
neither engine names the model it runs, so it is not applied. Quality below the cap is measured
on a team's own golden set (ADR-0037).

**Why a questions macro and not a `meta.ai_decide` entry.** `meta.ai_prompt`
([ADR-0035](0035-per-call-token-estimate-for-the-guard-and-the-log.md)) exists because a prompt's
name and version were literals repeated in the body and both hooks, and a bump missed in a hook
undercounted without failing. `decide`'s questions are a dict, which `meta` cannot usefully hold,
so a meta entry would have to name a versioned questions macro, a new kind of versioned artifact
with its own resolver. A project macro returning the questions already gives the body and both
hooks one definition with no literal to drift, so the meta entry would add the resolver without
removing any repetition. The governed path for a fixed label set, the vocabulary pipeline, already
names its questions once through `meta.ai_vocabulary` (ADR-0037).

**Why serialize the questions by hand.** `tojson` behaves differently on the two engines this
package supports. The same call, `tojson({"topic": {"type": "choice", "instructions": "x",
"criteria": {"zebra": "z", "apple": "a"}}, "alpha": {"type": "noul", "instructions": "y"}})`,
rendered on dbt Core 1.12 and dbt Fusion 2.0.9:

```
Core:   {"topic": {"type": "choice", "instructions": "x", "criteria": {"zebra": "z", "apple": "a"}}, "alpha": {"type": "noul", "instructions": "y"}}
Fusion: {"alpha": {"instructions": "y", "type": "noul"}, "topic": {"criteria": {"apple": "a", "zebra": "z"}, "instructions": "x", "type": "choice"}}
```

Fusion sorts keys at every level, so `tojson(questions)` would send choice labels in declared
order from one engine and alphabetical order from the other, for the same model and data. Both
engines iterate a dict in insertion order, so a serializer that walks the dict and encodes only
scalars with `tojson` produces the same text on both. Its token length equals `tojson`'s, since the
two differ only in order.

**Why not Jevflake or TypeSafe's API.** Both send row content out of the warehouse to TypeSafe.
[ADR-0012](0012-ai-as-a-row-level-sql-function.md) keeps inference in the warehouse's native AI
functions, so the data stays inside the warehouse boundary, and `decide` calls only those
functions.

## Consequences

- **Confidence is available as a column** on Databricks, and on Snowflake for an account that opts
  in.
- **BigQuery has no `decide`.** The README states the gap, and the vocabulary pipeline's
  `classify` fallback covers fixed-vocabulary labeling there.
- **The run log cannot record a versioned model id** for `decide`. On Databricks it records the
  function version; the model behind it can change without the log showing it.
- **A malformed question set fails at compile time,** before any call is billed.
- **dbt Core and Fusion send the same request** for the same questions; `assert_decide_questions_json`
  checks the exact serialized text on both engines.
- **CI and the integration tiers cover every branch.** duckdb reads seeded results for every
  question type and the error row, and asserts the unsupported-engine message and each validation
  message. The cloud tier runs a live choice, noul and score battery on Databricks, gated on
  `decide_available()`, and asserts the logged `est_tokens` equals the input estimate plus the
  questions JSON per row with no output allowance.

## Alternatives considered

- **A decision-model backend behind `classify`.** Rejected: breaks the scalar contract and
  silently changes existing labels.
- **Normalize inside `decide`.** Rejected: one billed call per extracted field.
- **Ship Snowflake enabled.** Rejected: unvalidated shape, failure mode is silent nulls.
- **Omit Snowflake until validated.** Rejected: preview accounts would get nothing.
- **A soft warning below the cap.** Rejected: the only threshold available describes another
  model.
- **A `meta.ai_decide` entry naming the questions.** Rejected: needs a versioned questions-macro
  convention and resolver, and removes no repetition a project macro does not already remove.
- **Gemini token log-probabilities as a BigQuery `decide`.** Rejected: a generative model's token
  probability is not a decision model's distribution over labels.

## Glossary

- **Decision model**: a model that returns typed answers and probabilities instead of text.
- **Choice / noul / score**: pick one described label; probability a statement is true; position
  on an ordered rubric.
- **Confidence**: the model's own measure of certainty in a choice or score answer. In the
  Databricks sample above it differs from the top probability.
- **Envelope**: the wrapper around the answers in a raw result, Databricks' `response`,
  `metadata` and `error_message`.
- **`decide_available()`**: the macro that says whether `decide` runs on the current target.
- **Private preview**: a feature an engine offers only to accounts it has enrolled.

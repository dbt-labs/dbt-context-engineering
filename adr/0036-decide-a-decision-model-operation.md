# 36. Add `decide`: a sixth operation for decision models

## Status

Accepted, 2026-10-20; Snowflake path validated live 2026-10-27.

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
| Snowflake | `AI_COMPLETE(model => 'snowflake-decision' \| 'snowflake-decision-fast', prompt => TO_JSON({state, questions}))` | Yes | Private preview since 2026-10-07; the account needs `CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'` |
| BigQuery | None. `AI.CLASSIFY` takes label descriptions and returns the label only | No | |

Databricks' `questions` argument must be a constant: the same question definitions for every row.
A choice question allows 1 to 255 labels on Databricks. Snowflake documents two models.
`snowflake-decision` takes 2 to 32 labels per choice, 2 to 10 score levels, at most 32 questions
and 256 options per request (a noul counts 2, a score its levels), question ids of 1 to 64
characters, and a 256 KiB request. `snowflake-decision-fast`, which Snowflake recommends for
most workloads, takes up to 16 labels per choice within a 32k-token request; Snowflake documents
no other limits for it.

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
documents that the underlying model may change.

Snowflake's result is an OBJECT holding only `answers`, with no envelope, and its noul answer names
the probability `noul` rather than `probability`. A row that fails returns a bare NULL. With
`return_error_details => true` the result is wrapped as `{value, error}`. Our account returned,
for one choice, one noul and one score question on `snowflake-decision` (2026-10-27):

```json
{"value": {"answers": {
   "frustrated": {"noul": 0.8807970779778823, "type": "noul"},
   "tone": {"confidence": 0.808393287368993, "legend": {"0": "calm", "1": "concerned", "2": "upset"},
            "probabilities": {"0": 0.009689957666694409, "1": 0.11804785075397696,
                              "2": 0.8722621915793286},
            "score": 1.8625722339126343, "type": "score"},
   "topic": {"choice": "pipelines", "confidence": 0.9866142981514305,
             "probabilities": {"pipelines": 0.9933071490757153, "pricing": 0.006692850924284856},
             "type": "choice"}}},
 "error": null}
```

and, for a choice with one label, `null` without `return_error_details` and with it:

```json
{"value": null,
 "error": "invalid input format: question \"topic\" declares 1 options; at least 2 are required"}
```

`snowflake-decision-fast` returned no error for the same one-label request, consistent with
Snowflake documenting only an upper bound for it. Both models reject an unknown question type.

Without `CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'` the same call fails with "The model you
requested is unavailable in your region. To access it, enable cross region inference with
ANY_REGION."

A score is a probability-weighted position from 0 to n - 1, so it can be fractional. Snowflake
documents that probabilities never reach 0 or 1 (a noul stays within about 0.08 to 0.92) and
defines confidence as (n * p_max - 1) / (n - 1), which the `snowflake-decision` result above
matches. `snowflake-decision-fast` computes it differently: for the same request it returned a
topic confidence of 0.975 from a top probability of 0.9975, where that formula gives 0.995, and a
tone confidence of 0.230 from 0.5617, where it gives 0.343.

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
  instructions; a choice without a label-to-description mapping; a score without 2 to 10 levels;
  noul criteria with keys other than `true` and `false`; a choice label or description, score
  level or noul description that is not a non-empty string; a repeated score level. It also
  rejects anything outside `decide_limits()`, the current engine's documented limits: a choice
  over or under its label bounds, and on `snowflake-decision` more than 32 questions, more than
  256 options in all, or an id over 64 characters. A limit an engine does not document is not
  checked.
- `decide_questions_json(questions)` serializes the questions as JSON text in declared order:
  question ids as given, each question's fields as `type`, `instructions`, `criteria`, and choice
  labels as given. Scalars and lists go through `tojson`. Both engine paths send it, and hooks size
  `decide` with `log_ai_run('decide', ..., prompt=decide_questions_json(questions))`.
- The choice caps are `var('decide_choice_cap_databricks', 255)`,
  `var('decide_choice_cap_snowflake', 32)` and `var('decide_choice_cap_snowflake_fast', 16)`, the
  documented limits, raisable if an engine raises its own. No lower soft threshold is applied.
- `decide_available()` is true on Databricks, true on Snowflake only when
  `var('decide_snowflake_preview')` is true (compared as normalized text), and false everywhere
  else.
- `var('decide_snowflake_model')` picks the Snowflake model, `snowflake-decision-fast` by default
  or `snowflake-decision`; any other value raises, since its limits would be unknown.
- Where `decide_available()` is false, `decide()` raises at execute time: the platform does not
  yet offer a decision model this package can call; use `classify()`, which labels from the same
  fixed set without a confidence. On Snowflake the message adds that an enrolled account with
  `CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'` can opt in with `decide_snowflake_preview: true`.
- `databricks__decide` is `ai_decide(<state>, '<decide_questions_json>')`.
- `snowflake__decide` is `object_insert(to_object(to_variant(ai_complete(model => '<model>',
  prompt => '{"state": ' || to_json(to_variant(<state>)) || ', "questions": ' ||
  '<decide_questions_json>' || '}', return_error_details => true))), 'model', '<model>')`. The
  request is assembled as text because a Snowflake OBJECT does not keep key order. `to_variant`
  is needed because `to_varchar` rejects the OBJECT `return_error_details` returns.
- `decide_answer(decision, question, field, as_type)` reads `choice`, `confidence`,
  `probabilities`, `probabilities.<label>`, `score`, `legend` and `probability`, cast to `as_type`.
  The Databricks branch reads `response.answers.<question>.<field>`; the Snowflake branch reads
  `value.answers.<question>.<field>` and maps `probability` to `noul`; the default branch reads
  the Databricks envelope from a JSON string, which is what the duckdb tier seeds.
- `decide_error(decision)` returns Databricks' `error_message` and Snowflake's `error`.
- `decide_model(decision)` returns `ai_decide/<metadata.version>` on Databricks and, on Snowflake,
  the model name `snowflake__decide` stored with the row.
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

**Why Snowflake is opt-in.** Snowflake Decision is a private preview that needs an enrolled
account and an account-level parameter, `CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'`. On by
default, every other Snowflake account's build would fail at the model check. Off by default, an
account that has both opts in knowingly, and the vocabulary pipeline uses its `classify`
fallback everywhere else.

**Why `return_error_details`.** Without it a failed Snowflake row is a bare NULL, which reads
exactly like a row the model left unanswered, so an invalid request or a content filter would
pass through a green build as missing answers. With it, `decide_error` carries Snowflake's
message the way it carries Databricks' `error_message`, and the vocabulary pipeline's `error`
column means the same thing on both engines.

**Why the Snowflake model name is stored in each row.** Snowflake's result names no model, and the
two models compute confidence differently, so a confidence threshold calibrated on one does not
hold for the other. Reading the model name from the var at read time would label rows decided by
one model with the other's name after a switch. Storing it in the row keeps `decide_model`
truthful for every row.

**Why `snowflake-decision-fast` is the default.** Snowflake recommends it for most workloads.
Snowflake documents fewer limits for it, so `validate_decide_questions` checks only its 16-label
choice cap, and a request over an undocumented limit surfaces as a per-row `decide_error` rather
than a compile error. A vocabulary over 16 terms, or one that needs every documented limit
checked, sets `decide_snowflake_model: snowflake-decision`. Both models pass the same live
battery.

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
  in. **It is model-specific:** the two Snowflake models compute it differently, so a vocabulary
  threshold is calibrated per engine and model.
- **A failed row is reported, not blank,** on both engines: `decide_error` returns the engine's
  message.
- **BigQuery has no `decide`.** The README states the gap, and the vocabulary pipeline's
  `classify` fallback covers fixed-vocabulary labeling there.
- **The run log cannot record a versioned model id** for `decide`. On Databricks it records the
  function version; the model behind it can change without the log showing it.
- **A malformed question set fails at compile time,** before any call is billed, and so does one
  over an engine's documented limits.
- **dbt Core and Fusion send the same request** for the same questions; `assert_decide_questions_json`
  checks the exact serialized text on both engines.
- **CI and the integration tiers cover every branch.** duckdb reads seeded results for every
  question type and the error row, and asserts the unsupported-engine message and each validation
  message, including each limit check. The cloud tier runs a live choice, noul and score battery
  on Databricks and, with the opt-in, on both Snowflake models, gated on `decide_available()`, and
  asserts the logged `est_tokens` equals the input estimate plus the questions JSON per row with no
  output allowance. On Snowflake it also sends a request Snowflake rejects and asserts its message
  reaches `decide_error`.

## Alternatives considered

- **A decision-model backend behind `classify`.** Rejected: breaks the scalar contract and
  silently changes existing labels.
- **Normalize inside `decide`.** Rejected: one billed call per extracted field.
- **Ship Snowflake enabled.** Rejected: the preview is access-gated, so accounts without it would
  fail.
- **Omit Snowflake.** Rejected: preview accounts would get nothing.
- **Read Snowflake's bare result and treat NULL as an error.** Rejected: a NULL cannot say why, and
  `decide_error` would have no message to return.
- **Default to `snowflake-decision`.** Rejected: Snowflake recommends the fast model for most
  workloads, and the higher choice cap and fuller limit checks are one var away.
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
  `metadata` and `error_message`, or Snowflake's `value` and `error` under `return_error_details`.
- **`decide_available()`**: the macro that says whether `decide` runs on the current target.
- **Private preview**: a feature an engine offers only to accounts it has enrolled.

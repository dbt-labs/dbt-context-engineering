# 37. Fixed-vocabulary classification with confidence routing and reviewer precedence

## Status

Accepted, 2026-10-20.

## Concept

A **controlled vocabulary** is a fixed list of terms, each with a definition and guidance on where
its boundary lies. Classifying text against one means every row ends up with exactly one of those
terms, so downstream filters and counts mean the same thing every time.

Three ideas make that trustworthy at scale. The vocabulary is **versioned**, so a change to it is a
reviewable event, not a silent edit. Each row's label carries a **confidence**, so a pipeline can
accept the clear calls and send the uncertain ones to a person (**confidence routing**). And a
person's decision is final: once a reviewer approves a term for a row, no rebuild relabels it
(**reviewer precedence**).

This record builds that pipeline on [ADR-0036](0036-decide-a-decision-model-operation.md)'s
`decide`, and falls back to `classify` where `decide` is unavailable.

## Context

The README's classification write-up names two limits: `classify` has no cache metadata, so a
rebuild relabels the whole corpus; and the taxonomy was shaped for one demo. A label set in a
schema `enum` ([ADR-0009](0009-portable-enum-enforcement-via-prompt-injection.md)) carries labels
only, no definitions.

`decide` returns a confidence on Databricks, and on Snowflake for an account that opts in.
BigQuery, and Snowflake without the opt-in, have no decision model. `classify` works everywhere and
returns a label with no confidence.

Databricks requires `decide`'s questions as a constant, so the vocabulary must be available at
compile time. Prompts and schemas already live as versioned macros resolved at compile time
([ADR-0001](0001-prompts-and-schemas-as-versioned-macros.md),
[ADR-0032](0032-dbt-version-floor-and-fusion-support.md)).

A row-level expression that reads one AI result several times can call the model several times
(ADR-0036). Human review decisions cannot be regenerated if lost.

## Decision

**We will define each vocabulary version as a macro, name it once per model in
`meta.ai_vocabulary`, render it into both `decide`'s choice criteria and `classify`'s schema enum,
and build a two-model pipeline in which the AI call is stored once, rows are routed by confidence,
rows with a review are never re-decided, and the latest review always wins.**

Vocabulary, in `macros/vocabulary/vocabulary.sql`:

- A version is `vocabulary__<name>__<version>()` in the calling project, resolved by
  `vocabulary(name, version)`, returning `instructions` and `terms`. A term has `label`
  (lowercase identifier, unique), `definition` (required), `scope_note`, `status` (`active`
  default, or `deprecated`), `valid_from`, `valid_to` and `synonyms`. `validate_vocabulary` rejects
  a malformed vocabulary at execute time.
- Only active terms are offered to a model. `vocabulary_question` renders one choice question,
  `term`, whose criteria are each active term's definition, scope note and synonyms.
  `vocabulary_schema` renders the same labels as a `classify` enum, and `vocabulary_prompt` the
  same descriptions as a `classify` prompt.
- `vocabulary_rows()` renders every term, every status, as rows for a `dim_vocabulary` model.

Naming the vocabulary:

- A model names its vocabulary once, in `config(meta={'ai_vocabulary': {'name': ..., 'version':
  ...}})`, the pattern `meta.ai_prompt` set in ADR-0035. Every vocabulary macro takes `name=` and
  `version=` as optional overrides and otherwise reads the entry through `vocabulary_ref()`; an
  explicit argument wins. At execute time a model with neither raises, naming the meta entry.
  During parse, where node config is not resolved, `vocabulary()` returns a one-term placeholder.
- `resolve_call_prompt`, which `guard_batch` and `log_ai_run` already use for `meta.ai_prompt`,
  also reads `meta.ai_vocabulary`: the per-row text is `vocabulary_sent_prompt()` and
  `vocabulary_sent_schema()` for the model's method, and on the decide path the default output
  allowance is 0. The hooks of a vocabulary model take no prompt, schema or output arguments.

Method:

- `vocabulary_method()` is `decide` where `decide_available()`. Elsewhere it follows
  `var('decide_fallback')`: `error` (the default) raises, saying the platform does not yet support
  decision models and that `decide_fallback: classify` is the correct route; `classify` uses
  `classify()` with the vocabulary's prompt and schema.

Pipeline:

1. `vocabulary_decide(relation, id_column, text_column, filter=)`, an incremental
   model keyed on `id_column`. One AI call per row in the batch. Stores `content_hash`,
   `vocabulary_name`, `vocabulary_version`, `vocabulary_key` (`name@version/method`), `method`,
   `decision` (raw `decide` result) or `classified_term`, and `decided_at`.
2. `vocabulary_labels(decided_relation, id_column, threshold=, review_relation=)`, a
   table, no AI call. Returns `term`, `confidence`, `runner_up`, `runner_up_probability`, `method`,
   `decision_model`, `vocabulary_name`, `vocabulary_version`, `status`, `approved_term`, `reviewer`,
   `reviewed_at`, `final_term`, `final_status` and `error`.

Routing and review:

- `status` on the decide path is `accepted` when `confidence >= threshold`, else `needs_review`; a
  missing answer, an engine error, or a term outside the active vocabulary is `needs_review`.
  `threshold` is required on the decide path and has no default.
- On the classify path every row with an active term is `unscored`, otherwise `needs_review`.
- `runner_up` is the most probable active term other than the chosen one, ties broken by label.
- `review_relation` is a user-owned relation the package only reads: `<id_column>`,
  `approved_term`, `reviewer`, `reviewed_at`. It is passed as a relation, so it can be a seed,
  model or source in the user's project. Omitted, the join is skipped. The latest review per id
  wins. `final_term` is the approved term when present, otherwise the term for `accepted` and
  `unscored` rows, otherwise null. `final_status` is `reviewed` for reviewed rows, otherwise
  `status`.
- `vocabulary_labels` refuses to read a decided relation built against a different vocabulary.
  At execute time it runs `select distinct vocabulary_key` on the decided relation and raises,
  before writing, if any key differs from its own `name@version/method`, naming both and saying to
  rebuild the decided model or align the two models' `meta.ai_vocabulary`. An empty relation
  passes.
- `final_term` is the column to map to `knowledge_base`'s `classification`
  ([ADR-0027](0027-classification-as-a-second-privileged-knowledge-base-column.md)).

Delta:

- `vocabulary_delta_predicate(id_column, review_relation=)` is shared by the
  decided model's body, `guard_batch` and `log_ai_run`. It wraps `incremental_delta_predicate`
  with `vocabulary_key` as the version and `content_hash` as the content column
  ([ADR-0004](0004-version-aware-incremental-refresh.md),
  [ADR-0023](0023-embedding-metadata-and-content-hash-delta.md)), and excludes every id with an
  approved review, on every run including the first.
- The hooks count each row's vocabulary text through `resolve_call_prompt` (see Naming the
  vocabulary, and [ADR-0035](0035-per-call-token-estimate-for-the-guard-and-the-log.md)).

Evaluation:

- `eval(..., confidence_column=)` adds `accuracy_by_confidence` and `count_by_confidence` rows per
  bucket, `0.0-0.5`, `0.5-0.7`, `0.7-0.8`, `0.8-0.9`, `0.9-1.0`, and `unscored` for a null
  confidence.

```sql
-- vocab_decided.sql
{{ config(
    materialized='incremental', unique_key='utterance_id',
    meta={'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}},
    pre_hook=[
        "{{ dbt_context_engineering.guard_batch(ref('vocab_stg'), 'utterance_text', filter=vocab_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run(dbt_context_engineering.vocabulary_method(),
             relation=ref('vocab_stg'), input_column='utterance_text', filter=vocab_delta_filter()) }}"]
) }}
{{ dbt_context_engineering.vocabulary_decide(ref('vocab_stg'), 'utterance_id', 'utterance_text',
    filter=vocab_delta_filter()) }}

-- vocab_labels.sql (table, same meta.ai_vocabulary)
{{ dbt_context_engineering.vocabulary_labels(ref('vocab_decided'), 'utterance_id',
    threshold=0.6, review_relation=ref('vocab_reviews')) }}
```

`vocab_delta_filter()` is a project macro returning
`vocabulary_delta_predicate('utterance_id', review_relation=ref('vocab_reviews'))`, so the body and
both hooks share it.

## Reasoning

**Why a macro and not a seed.** `decide` needs the questions as a constant at compile time, and a
seed is not readable then. The macro form is the established pattern for prompts and schemas, and
a version bump is an explicit, reviewable diff. A user who wants a spreadsheet can still generate
the macro from one; the package reads only the macro.

**Why name the vocabulary in `meta`.** The body, the delta filter and both hooks all need it. As
arguments it would be written four times per model, and a version bump missed in a hook would size
the batch against the wrong vocabulary without failing, the failure ADR-0035 removed for prompts.
One `meta` entry serves all four, records in the manifest which vocabulary version each model
uses, and matches `meta.ai_prompt`, so a reader meets one idiom for both. A body/filter mismatch is
worse than a mis-sized estimate: `version_guard` would see a different key on every run and
reprocess the whole corpus each time. `vocab_labels` and `dim_vocabulary` name the vocabulary only
once each; they use the same entry so the pipeline reads with one idiom throughout.

**Why one vocabulary renders both paths.** If the `decide` criteria and the `classify` enum were
written separately they would drift, the failure ADR-0009's single-source principle exists to
prevent. Rendering both from one definition means a term added, retired or redefined changes
both.

**Why two models.** The labels step reads the AI result for the term, the confidence, every
label's probability and the error. In one query those reads could each trigger a model call.
Storing the result in an incremental model and reading it in a separate table bills one call per
row.

**Why `unscored` rather than `needs_review` on the classify path.** `classify` is a valid method
that returns a label; `decide` is the higher-quality one because it also says how sure it is.
Sending every fallback row to review would leave `final_term` empty on two of three engines until
someone reviewed the whole corpus. `unscored` rows reach `final_term`, which is what `classify`
already provides today, and the status says plainly that no confidence stood behind them.

**Why no default threshold.** The right threshold depends on the vocabulary, the text and the cost
of an error. A default would be a number nobody chose. `eval` with `confidence_column` on a golden
set is how a team chooses it.

**Why version skew between the two models stops the build.** Each model names its vocabulary
in its own `meta`, so they can disagree: one bumped and the other not, or both bumped and only the
labels model rebuilt. Reading answers decided against another version misroutes rows without
failing: a term the new version retired counts as outside the vocabulary and goes to review, and
the runner-up reads probabilities for labels the answers never had. A mismatch is a configuration
mistake, not a property of the data, so it fails the build rather than being routed. The key
includes the method, so a switch from the `classify` fallback to `decide` that has not been
rebuilt is caught the same way.

**Why reviewed rows are never re-decided.** A reviewed row's term comes from the review, on every
build. Re-deciding it would spend without changing the output, and on a vocabulary change the
review still stands until a person revisits it.

**Why the review table is passed in and only read.** Human decisions are the one input here that
cannot be regenerated. A package-shipped seed would put them where a `dbt seed --full-refresh` or
a merge conflict could lose them. Passing a relation lets the user own the table and choose its
form.

## Consequences

- **Fixed-vocabulary labels on every engine:** with confidence routing on Databricks (and on
  Snowflake with the preview opt-in), and as `unscored` labels via `classify` on BigQuery and
  Snowflake without it.
- **Rebuilds are stable:** a row is re-decided only when its text, the vocabulary version or the
  method changes, and never once reviewed.
- **The two models cannot silently disagree on the vocabulary.** A labels build against a decided
  relation holding another version or method fails, naming both keys, at the cost of one small
  query per labels build.
- **Switching method changes the `decision` column's type,** for example when an account turns on
  `decide_snowflake_preview`; that build needs `--full-refresh`.
- **A vocabulary label must be an identifier,** because it is a path segment when reading
  probabilities.
- **Extends ADR-0035's resolver.** `resolve_call_prompt` reads `meta.ai_vocabulary` after
  `meta.ai_prompt` and returns a third element, the output allowance the meta implies. ADR-0035's
  behavior for `meta.ai_prompt` is unchanged.
- **A vocabulary model names its vocabulary once,** and its hooks need no prompt arguments. The
  cloud tier asserts that `log_ai_run`, given none, logs `est_tokens` equal to the estimate over the
  rows actually sent for the text that engine's method carries.
- **The test tiers cover it.** duckdb tests routing at the threshold boundary, runner-up ranking and
  tie-break, a term outside the vocabulary, an engine error, the latest of two reviews winning, a
  reviewed row with no decision, the classify path, the reviewed-row exclusion in the delta
  predicate, the rendered question, schema and prompt, the confidence buckets, the fallback
  message, the missing-vocabulary message, the version-skew message and each validation message. The cloud tier runs the pipeline live on all three engines:
  `decide` on Databricks, the `classify` fallback on Snowflake and BigQuery, with the same
  assertions branching on method.
- **The cloud run-log assertions for `signals` are scoped by `model_name`,** since the classify
  fallback logs `classify` runs in the same invocation.

## Alternatives considered

- **Vocabulary as a seed.** Rejected: not readable at compile time, no explicit versions.
- **One model for the AI call and the reading.** Rejected: risks one billed call per read.
- **Fallback rows as `needs_review`.** Rejected: empty `final_term` on two engines until a full
  review.
- **Route rows from a mismatched vocabulary to `needs_review`.** Rejected: a configuration mistake
  would surface only as a growing review queue, with the build green.
- **A default confidence threshold.** Rejected: no evidence behind any single number.
- **Vocabulary name and version as arguments on every macro and hook.** Rejected: four references
  per model, and a missed bump in a hook sizes against the wrong vocabulary silently.
- **A package-shipped review seed, or a var naming the review table.** Rejected: the seed risks
  losing decisions, and a var cannot carry a `ref()`, so lineage would not track the table.

## Glossary

- **Controlled vocabulary**: a fixed, versioned list of terms with definitions.
- **Scope note**: guidance on where a term's boundary lies, what it does and does not cover.
- **Confidence routing**: accepting a model's answer at or above a threshold and sending the rest to
  review.
- **Reviewer precedence**: a person's approved term always wins over the model's.
- **`unscored`**: a label from `classify`, valid but with no confidence behind it.
- **Runner-up**: the most probable term other than the one the model chose.
- **Golden set**: rows with known correct labels, used to measure accuracy.
- **`meta.ai_vocabulary`**: the model config entry naming its vocabulary's `name` and `version`,
  read by every vocabulary macro and by `guard_batch` and `log_ai_run`.

# AI functions — full reference

Every function is called package-qualified inside a model's `SELECT` and processes one row at a
time. All require `var: ai_functions_enabled = true` and their model var (see `dbt-ce-setup`),
and the calling model must be `table` or `incremental`, never `view`.

## generate

```
generate(input_column, prompt, output_schema=none, model=none)
```

Free-form generation. Pass `output_schema` only to get a structured object instead of plain
text. `model` defaults to `var: model_generate`.

```sql
select id,
  {{ dbt_context_engineering.generate('article_body',
       dbt_context_engineering.prompt('summarize', 'v1')) }} as summary_raw
from {{ ref('articles') }}
```

Read the result:
- unstructured → `text(ai_result)` for the plain string.
- structured → `field(ai_result, 'field_name', as_type='...')`.

## classify

```
classify(input_column, prompt=none, output_schema=none, model=none)
```

Single label from a closed taxonomy. **`output_schema` is required** — its `enum` is the label
set. Returns a **plain scalar string** on all engines (no unwrapping needed). `model` defaults to
`var: model_classify`.

```sql
select ticket_id,
  {{ dbt_context_engineering.classify('ticket_body',
       dbt_context_engineering.prompt('ticket_priority', 'v1'),
       dbt_context_engineering.schema_def('ticket_priority', 'v1')) }} as priority
from {{ ref('stg_tickets') }}
```

## extract

```
extract(input_column, prompt=none, output_schema=none, model=none)
```

Typed extraction into a structured record. **`output_schema` is required.** Include an
**evidence/quote field** in the schema so each fact carries its supporting source text (a package
invariant; enables the `grounded` test). `model` defaults to `var: model_extract` →
`var: model_generate`.

```sql
select doc_id, ticket_text,
  {{ dbt_context_engineering.extract('ticket_text',
       dbt_context_engineering.prompt('fact_extract', 'v1'),
       dbt_context_engineering.schema_def('fact_extract', 'v1')) }} as facts_raw
from {{ ref('tickets') }}
```

Flatten a field for testing/use:
```sql
select doc_id, ticket_text,
  {{ dbt_context_engineering.field('facts_raw', 'quote') }} as quote
from {{ ref('extracted') }}
```

## ai_agg

```
ai_agg(input_column, prompt, order_column=none, model=none)
```

Group-level aggregation — reasons across every row in a `GROUP BY` group and returns one answer
per group. **`prompt` is a plain instruction string, not a template** (no `{{ input }}`
placeholder, the function feeds it the group's rows). `order_column` sets the order rows are
presented within a group. `model` defaults to `var: model_agg` → `var: model_generate`.

```sql
select call_id,
  {{ dbt_context_engineering.ai_agg('utterance_text',
       'Summarize the key objections raised across this call.',
       order_column='turn_index') }} as call_summary
from {{ ref('stg_gong__transcripts') }}
group by call_id
```

On **Databricks**, `ai_agg` has no internal map-reduce, so guard each group:
```sql
{{ config(pre_hook="{{ dbt_context_engineering.guard_agg_batch(
     relation=this, input_column='utterance_text', group_by_column='call_id') }}") }}
```
Set `var: max_agg_group_tokens` accordingly (see `dbt-ce-setup`).

**Per-engine behavior of `order_column` and `model` (ADR-0028) — don't assume they're portable:**
- `order_column`: honored on **Databricks**; a **no-op on BigQuery**; on **Snowflake** the macro
  cannot reorder the `FROM`, so pre-sort the input yourself (feed `ai_agg` an already-ordered CTE)
  if within-group order matters.
- `model`: honored on **Databricks** and **BigQuery**; a **no-op on Snowflake** (Cortex picks the
  model internally). This is the same reason `model_classify` is ignored on Snowflake.

If order within a group matters and you target Snowflake, sort in a CTE first rather than relying
on `order_column`.

## decide

```
decide(state_column, questions)
decide_answer(decision, question, field, as_type=none)   decide_error(decision)   decide_model(decision)
```
- `questions`: dict keyed by question id (letters, digits, underscores). Each has `type`,
  `instructions` and `criteria`:
  - `choice`: `criteria` maps label to description, 1 to `decide_choice_cap_<engine>` labels
    (Databricks 255, Snowflake 32). Fields: `choice`, `confidence`, `probabilities`,
    `probabilities.<label>`.
  - `noul`: optional `criteria` with `true` / `false` descriptions. Field: `probability`.
  - `score`: `criteria` is a list of 2-10 levels, lowest first. Fields: `score`, `confidence`,
    `legend`, `probabilities`.
- Malformed questions fail at compile time.
- Returns the raw engine result. Materialize it, then read fields in a downstream model; reading
  several fields of a `decide()` call in one query can call the model once per field.
- Engines: Databricks `ai_decide` (Beta). Snowflake `AI_COMPLETE('snowflake-decision')`, private
  preview, only with `decide_snowflake_preview: true`, unvalidated. BigQuery: none; raises, naming
  `classify`. `decide_available()` reports which applies.
- `decide_error` is Databricks' per-row `error_message` (Snowflake fails the query instead).
  `decide_model` is `ai_decide/<function version>` on Databricks; neither engine exposes a
  versioned model id.
- Cost: `log_ai_run('decide', ..., prompt=tojson(questions))` counts the questions on every row
  with no output allowance, since a decision model returns typed answers rather than generated
  text. Neither engine publishes how `decide` is billed, so treat its `est_tokens` as request size.
- Define the questions in a macro in your project and call it from the body and both hooks, so all
  three share one definition. Inline questions in the body cannot be reached from a hook.

## Fixed-vocabulary pipeline

A vocabulary version is a macro in your project:

```sql
{% macro vocabulary__ticket_topics__v1() -%}
    {{ return({'instructions': 'What is this ticket mainly about?',
               'terms': [{'label': 'billing', 'definition': 'Payments, invoices, refunds.',
                          'scope_note': 'Not pricing questions before purchase.'},
                         {'label': 'outage', 'definition': 'The product is down or erroring.'},
                         {'label': 'other', 'definition': 'Anything else.'}]}) }}
{%- endmacro %}
```

Two models, plus your own review table (`<id>`, `approved_term`, `reviewer`, `reviewed_at`). Each
model names the vocabulary once in `meta.ai_vocabulary`; the macros and both hooks read it, so the
hooks need no prompt arguments:

```sql
-- ticket_topics_decided.sql; input relation carries ticket_id, body, and content_hash (content_hash('body'))
{{ config(
    materialized='incremental', unique_key='ticket_id', full_refresh=var('allow_full_redecide', false),
    meta={'ai_vocabulary': {'name': 'ticket_topics', 'version': 'v1'}},
    pre_hook=[
        "{{ dbt_context_engineering.guard_batch(ref('stg_tickets'), 'body', filter=ticket_topics_delta()) }}",
        "{{ dbt_context_engineering.log_ai_run(dbt_context_engineering.vocabulary_method(),
             relation=ref('stg_tickets'), input_column='body', filter=ticket_topics_delta()) }}"],
    post_hook="{{ dbt_context_engineering.complete_ai_run(dbt_context_engineering.vocabulary_method()) }}"
) }}
{{ dbt_context_engineering.vocabulary_decide(ref('stg_tickets'), 'ticket_id', 'body', filter=ticket_topics_delta()) }}

-- ticket_topics.sql: table, same meta.ai_vocabulary
{{ dbt_context_engineering.vocabulary_labels(ref('ticket_topics_decided'), 'ticket_id',
    threshold=0.8, review_relation=ref('ticket_topic_reviews')) }}
```

where `ticket_topics_delta()` is a project macro returning
`vocabulary_delta_predicate('ticket_id', review_relation=ref('ticket_topic_reviews'))`. A model
with neither `meta.ai_vocabulary` nor `name=` / `version=` fails at compile time.

- `status`: `accepted` (confidence at or above `threshold`), `needs_review`, or `unscored`
  (`classify` fallback). `final_term` is the reviewed term, else the term for `accepted` /
  `unscored` rows; map it to `knowledge_base`'s `classification`.
- On an engine without `decide`, set `decide_fallback: classify`; the default `error` stops with
  that instruction.
- Choose `threshold` with `eval(relation, pred, expected, confidence_column='confidence')` on a
  golden set: it adds accuracy and count per confidence bucket.
- `vocabulary_rows()` builds a `dim_vocabulary` model of every term (set the same meta entry).
- Bump both models' `meta.ai_vocabulary` together and rebuild the decided model: `vocabulary_labels`
  stops the build if the decided rows came from a different vocabulary version or method.

## Reading structured output

| helper | returns |
|---|---|
| `text(ai_result)` | plain text of an unstructured `generate` |
| `field(ai_result, field, as_type=none)` | one field of a structured `generate`/`extract`, cast to `as_type` |

These exist because each engine wraps structured output differently (Snowflake `:response`
envelope, BigQuery `.result` struct / `.<field>` access, Databricks JSON). `text`/`field`
normalize that so your model reads the same on every adapter. **Flatten with `field()` before**
`conforms_to_schema` (label check) or a `grounded` test (quote check).

## Per-engine notes

- **Enum enforcement:** Snowflake/Databricks structured output carries the enum natively;
  BigQuery's output schema can't, so the wrappers inject the allowed values into the prompt from
  the schema `enum` automatically — you still define the enum once in `schema_def`.
- **Output caps:** `var: max_output_tokens` bounds `generate` on all three; on Snowflake/
  Databricks `classify`/`extract` are bounded by their schema, no separate cap. On BigQuery set
  `var: bq_thinking_budget: 0` for structured tasks.
- **generate/extract are beta** in the package (validated but with `LIVE-VALIDATION DEFERRED`
  aspects); `classify` and `embed` are the most exercised.

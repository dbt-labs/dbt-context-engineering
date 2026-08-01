# 18. Converge the Snowflake extract path onto AI_COMPLETE

## Status

Accepted, 2026-07-31.

## Concept

A **taxonomy** only holds if the engine actually **binds** the model to it. A label set reaches the
model through the **structured-output schema** (the function enforces the `enum`) or through the
**prompt text** (the labels are written into the instructions). Schema binding is the strong form:
the output cannot leave the set. Prompt instruction is the weak form: it steers but does not bind.

The deeper principle is that **"extract" is not a distinct capability from "generate a structured
answer"**. On the engines that work here, extraction *is* the structured-generate primitive pointed
at a schema. The right primitive for a field with an `enum` is whichever one the engine will bind to
that `enum`, and for two of three engines that is already their generate function.

## Context

Issue #3: on the Snowflake tier `assert_extract_conforms_sf` failed deterministically while the same
assertion passed on Databricks and BigQuery. Two facts, both proven (see Evidence), explain it:

1. **Snowflake was the lone platform using a dedicated extract function.** `ce_extract` runs on
   `ai_query` (Databricks) and `AI.GENERATE` (BigQuery), each engine's *structured-generate*
   primitive, which binds the schema (`json_schema strict`, `output_schema` + injection). Only
   Snowflake used `AI_EXTRACT`, a separate function from its generate primitive `AI_COMPLETE`.
2. **`AI_EXTRACT` cannot bind an `enum` and marks absence with a string.** Its `responseFormat`
   schema supports only a string scalar (no `enum`, per Snowflake docs), and it returns the literal
   string `"None"` for a field it cannot fill. So `signal` came back either an off-taxonomy value or
   `"None"`, neither of which is in the taxonomy.

## Decision

**We will implement `snowflake__ce_extract` with `AI_COMPLETE` + `response_format`, the same
structured-generate primitive `ce_generate` uses, instead of `AI_EXTRACT`.** This binds the `enum`
structurally and makes all three cloud engines implement extract via structured generate. The result
is the fields object directly (no `:response` envelope), read by the existing `ce_field` path. In the
shared v3 schema, `signal` stays `required` (a classification always resolves, `other` is the floor)
and `evidence` becomes optional (a supporting quote can be genuinely absent, and a `required` field
`AI_COMPLETE` cannot fill is fabricated).

```sql
-- snowflake__ce_extract
ai_complete(
    model => '{{ model }}',
    prompt => {{ ce_render_prompt(prompt, input_column) }},
    response_format => {'type': 'json', 'schema': parse_json($${{ output_schema }}$$)}
)
-- v3 schema: "required": ["signal"]   (evidence optional)
```

## Reasoning

**Why bind in the schema rather than steer with the prompt.** Writing the labels into the prompt only
steers the model; it cannot prevent an off-taxonomy or `"None"` value. `AI_COMPLETE` binds the `enum`
in the schema, so a non-conforming value cannot be returned. Binding beats steering.

**Why this is convergence, not a Snowflake-only deviation.** Databricks and BigQuery already
implement `ce_extract` through their generate primitive. `AI_EXTRACT` was the anomaly. Moving
Snowflake to `AI_COMPLETE` removes the inconsistency rather than adding one, which was the bar set
for deviating on a single platform.

**Why `evidence` is optional and `signal` required.** They are different kinds of field. `signal` is
a classification: every segment resolves to a label, so `required` is safe and never fabricates.
`evidence` is an extraction: a quote may legitimately not exist, and a `required` field `AI_COMPLETE`
cannot fill is invented (fabricating an ungrounded citation, the exact thing the grounded test
guards). Optional lets absence be null.

## Consequences

- **The Snowflake conformance and groundedness failures resolve structurally**, and the extract path
  reaches true parity with Databricks and BigQuery. Confirmed by re-running the three cloud tiers.
- **All three cloud engines now implement `ce_extract` via structured generate**, and `AI_EXTRACT` is
  no longer used in the package.
- **`ce_extract` on Snowflake now needs a model var** (`ce_model_extract` or `ce_model_generate`),
  because `AI_COMPLETE` takes a model where `AI_EXTRACT` did not.
- **The v3 schema change (`evidence` optional) is shared across engines.** It is globally correct and
  prevents the same fabrication on the other tiers.

## Evidence

Both primitives were probed directly against Snowflake with the real v3 schema and inputs.

`AI_EXTRACT` returns the literal string `"None"` for a field it cannot fill. On the segment that
defeated conformance:

```sql
select ai_extract(
    text => $$Classify the segment into one signal label; include the verbatim quote.
Segment: And nobody on the team can tell which model actually failed.$$,
    responseFormat => { 'schema': parse_json($$
      {"type":"object","properties":{
        "signal":{"type":"string","enum":["pain_point","requirement","objection","buying_signal","other"]},
        "evidence":{"type":"string"}}}$$) }
);
-- -> { "error": null, "response": { "signal": "None", "evidence": "None" } }
```

`signal = "None"` is not in the taxonomy (fails conformance) and `evidence = "None"` is not in the
utterance (fails groundedness). The same happens for any unfillable field: asking for an email that
the text does not contain returns `"customer_email": "None"`. So `"None"` is `AI_EXTRACT`'s
"could not fill" sentinel, and its `responseFormat` never enforced the `enum`.

`AI_COMPLETE` + `response_format` binds the `enum` on the same segment:

```sql
select ai_complete(
    model => 'mistral-large2',
    prompt => $$Classify the segment into one signal label; include the verbatim quote.
Segment: And nobody on the team can tell which model actually failed.$$,
    response_format => { 'type': 'json', 'schema': parse_json($$
      {"type":"object","properties":{
        "signal":{"type":"string","enum":["pain_point","requirement","objection","buying_signal","other"]},
        "evidence":{"type":"string"}}, "required":["signal"]}$$) }
);
-- -> { "signal": "pain_point",
--      "evidence": "And nobody on the team can tell which model actually failed." }
```

`signal` is a valid taxonomy label and `evidence` is a verbatim quote, stable across four runs, with
no `"None"`.

`AI_COMPLETE` enforces `required` by fabricating a value it cannot extract. With a `required` field
the text cannot supply:

```sql
select ai_complete(
    model => 'mistral-large2',
    prompt => $$The customer said the nightly data pipeline keeps breaking during the load.$$,
    response_format => { 'type': 'json', 'schema': parse_json($$
      {"type":"object","properties":{
        "stated_problem":{"type":"string"},"customer_email":{"type":"string"}},
       "required":["stated_problem","customer_email"]}$$) }
);
-- -> { "stated_problem": "...", "customer_email": "customer@example.com" }   (fabricated)
```

The invented email is why `evidence` must be optional: a `required` evidence field on a quote-less
row would manufacture an ungrounded citation.

## Alternatives considered

1. **Steer with prompt-injected enums instead of binding in the schema.** Rejected: prompt
   instruction is advisory and cannot prevent an off-taxonomy or `"None"` value, and it would keep
   Snowflake on `AI_EXTRACT`, a primitive no other tier uses.
2. **Keep `evidence` required under `AI_COMPLETE`.** Rejected: a `required` field the model cannot
   fill is fabricated (see Evidence), which would manufacture ungrounded citations.

## Glossary

- **Taxonomy / enum**: the fixed set of allowed labels, declared once as the `enum` of a schema
  property (`ce_schema`), single source of truth.
- **Structured-generate primitive**: an engine's generate function driven by an output schema
  (`AI_COMPLETE` `response_format`, Databricks `ai_query` `json_schema`, BigQuery `AI.GENERATE`
  `output_schema`). All three implement `ce_extract`.
- **`AI_EXTRACT` vs `AI_COMPLETE`**: two Snowflake Cortex functions. `AI_EXTRACT` is extraction-only,
  supports no `enum`, and marks an unfillable field with the string `"None"`. `AI_COMPLETE` +
  `response_format` binds an `enum` and enforces `required` (by fabricating when it cannot fill).
- **Binding vs steering**: a schema `enum` *binds* (output cannot leave the set); a prompt
  instruction *steers* (usually complied with, not guaranteed).
- **Groundedness**: whether an extracted evidence quote appears verbatim in the source text; asserted
  by `assert_extract_grounded_sf`. Absent (null) evidence is not flagged.

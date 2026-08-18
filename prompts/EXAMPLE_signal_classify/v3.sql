{#-
  Prompt + output schema for the EXAMPLE 'signal_classify' task, version v3.
  Canonical source (macro library, ADR-0001). prompt / schema resolve these to compile-time
  literals. {% raw %} keeps the {{ input }} placeholder literal — the function wrappers
  substitute the input column for it. This EXAMPLE is illustrative only:
  stg_gong__transcripts is never a real dependency.

  Allowed labels are NOT hand-listed here — they live once in the schema `enum` below. On engines
  whose structured output can't carry an enum (BigQuery), the wrappers auto-inject the allowed
  values into the prompt via augment_prompt, so the model is constrained everywhere from a single
  source of truth (see ADR-0009, structured-output divergence).
-#}

{% macro prompt__EXAMPLE_signal_classify__v3() -%}
{%- raw -%}
Classify the sales-call segment below into exactly one signal label.

Return only labels defined in the accompanying schema. Do not invent labels.
For each classification, include the verbatim quote that justifies it.

Segment:
{{ input }}
{%- endraw -%}
{%- endmacro %}


{% macro schema__EXAMPLE_signal_classify__v3() -%}
{%- raw -%}
{
  "type": "object",
  "properties": {
    "signal": {
      "type": "string",
      "enum": ["pain_point", "requirement", "objection", "buying_signal", "other"]
    },
    "evidence": {
      "type": "string",
      "description": "Verbatim quote from the segment supporting the label (lineage)."
    }
  },
  "required": ["signal"],
  "additionalProperties": false
}
{%- endraw -%}
{%- endmacro %}

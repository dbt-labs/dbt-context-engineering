{#-
  augment_prompt(prompt, output_schema) -> the prompt text with an explicit value-constraint
  block prepended for every enum field in output_schema, resolved at compile time.

  WHY: portable enum enforcement. Snowflake/Databricks structured output carries the enum (the model
  is constrained), but BigQuery's output_schema is a `name TYPE` list that CANNOT express an enum —
  bq_output_schema degrades it to plain STRING, so the model never sees the label set and invents
  its own ("PROBLEM", "Discovery Question", …; confirmed live 2026-07-29, see PARITY.md). Putting the
  allowed values in the prompt constrains the model on any engine. The schema enum stays the single
  source of truth — no hand-maintained label list in the prompt.

  Used by the BigQuery wrappers only (bigquery__generate/classify/extract). Snowflake/Databricks
  do NOT call it: their response_format / ai_classify categories already enforce the enum, and a
  constraint preamble would just pollute the model input (especially ai_classify's text argument).

  No-op when output_schema is none or has no enum property (returns prompt unchanged).
-#}
{% macro augment_prompt(prompt, output_schema) -%}
    {%- if output_schema is none -%}{{ return(prompt) }}{%- endif -%}
    {%- set sd = fromjson(output_schema) -%}
    {%- set ns = namespace(lines=[]) -%}
    {%- for pname, pdef in (sd.get('properties', {})).items() -%}
        {%- if pdef.get('enum') -%}
            {%- do ns.lines.append(
                '- "' ~ pname ~ '" must be exactly one of these values, copied verbatim '
                ~ '(do not invent, translate, capitalize, or reformat): ' ~ (pdef.get('enum') | join(', '))) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if (ns.lines | length) == 0 -%}{{ return(prompt) }}{%- endif -%}
    {%- set block = 'Follow these value constraints exactly:\n' ~ (ns.lines | join('\n')) ~ '\n\n' -%}
    {{ return(block ~ prompt) }}
{%- endmacro %}

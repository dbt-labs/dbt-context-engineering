{#-
  redshift_output_instruction(output_schema, mode) -> a plain-text instruction STRING appended to the
  prompt that tells a Bedrock text model how to shape its reply.

  WHY this exists (and only on Redshift): Snowflake AI_COMPLETE, Databricks ai_query, and BigQuery
  AI.GENERATE all enforce the output shape structurally (response_format / responseFormat /
  output_schema). Redshift ML's Bedrock integration returns PLAIN TEXT only — there is no
  response_format knob at all (confirmed against the CREATE EXTERNAL MODEL / Converse interface).
  So the output contract on Redshift is BEST-EFFORT, prompt-enforced, not structurally guaranteed:
  we describe the required shape in words and parse the model's text reply back with field()/trim().

  The output_schema stays the single source of truth — the key list, types, and enum constraints are
  all derived from it here, never hand-maintained in the prompt. augment_prompt already emits the enum
  value-constraint block (shared with BigQuery); this adds the SHAPE instruction that augment_prompt
  does not: "emit exactly these keys as JSON" (json) or "emit exactly one bare label" (label).

  mode='json'  — generate(structured) / extract: a single minified JSON object, schema's keys+types,
                 no prose or code fences. Read back with field() -> json_extract_path_text.
  mode='label' — classify: one bare enum label, nothing else. Read back with trim().

  Returns '' when there is nothing to say (json mode with no schema). See ADR (Redshift Bedrock).
-#}

{#- JSON Schema `type` -> a plain English word for the prompt. A type may be a bare string or a
    list (e.g. ["string","null"]); take the first non-null entry. Defaults to "string". -#}
{% macro _ce_rs_type_word(pdef) -%}
    {%- set t = pdef.get('type', 'string') -%}
    {%- if t is iterable and t is not string -%}
        {%- set ns = namespace(w='string') -%}
        {%- for x in t -%}{%- if x != 'null' and ns.w == 'string' -%}{%- set ns.w = x -%}{%- endif -%}{%- endfor -%}
        {{- return(ns.w) -}}
    {%- endif -%}
    {{- return(t) -}}
{%- endmacro %}


{% macro redshift_output_instruction(output_schema, mode) -%}
    {%- if mode == 'label' -%}
        {#- augment_prompt already listed the allowed values; here we only pin the SHAPE: a bare label. -#}
        {{- return('\n\nRespond with exactly one of the allowed values above, copied verbatim. '
            ~ 'Output only that single value — no quotes, JSON, markdown, prose, or explanation.') -}}
    {%- endif -%}

    {#- mode == 'json' -#}
    {%- if output_schema is none -%}{{ return('') }}{%- endif -%}
    {%- set sd = fromjson(output_schema) -%}
    {%- set props = sd.get('properties', {}) -%}
    {%- if (props | length) == 0 -%}{{ return('') }}{%- endif -%}
    {%- set keys = [] -%}
    {%- for pname, pdef in props.items() -%}
        {%- do keys.append(pname ~ ' (' ~ dbt_context_engineering._ce_rs_type_word(pdef) ~ ')') -%}
    {%- endfor -%}
    {{- return('\n\nRespond ONLY with a single minified JSON object and no other text. '
        ~ 'It must contain exactly these keys: ' ~ (keys | join(', ')) ~ '. '
        ~ 'Do not wrap it in markdown or code fences, and do not add any keys, prose, or explanation.') -}}
{%- endmacro %}

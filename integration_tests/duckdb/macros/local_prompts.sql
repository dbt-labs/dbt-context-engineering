{#- A prompt + schema defined in THIS (consuming) project, NOT in the package. Used by
    assert_local_prompt to prove ce_prompt / ce_schema resolve caller-defined definitions, not only
    ones shipped in dbt_context_engineering. Deliberately uses labels the package never defines
    (alpha_label/beta_label) so the assertion can't accidentally pass on a package fallback. -#}
{% macro ce_prompt__local_probe__v1() -%}
{%- raw -%}
PROJECT-DEFINED-PROMPT — classify the segment below:
{{ input }}
{%- endraw -%}
{%- endmacro %}

{% macro ce_schema__local_probe__v1() -%}
{%- raw -%}
{"type": "object", "properties": {"signal": {"type": "string", "enum": ["alpha_label", "beta_label"]}}, "required": ["signal"]}
{%- endraw -%}
{%- endmacro %}

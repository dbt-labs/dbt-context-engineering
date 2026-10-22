{#- Consumer-authored prompt/schema macros (ADR-0001 convention: prompt__<name>__<version> /
    schema__<name>__<version>, resolved by dbt_context_engineering.prompt()/schema_def()).
    {% raw %} keeps the {{ input }} placeholder literal so the wrappers substitute the column. -#}

{% macro prompt__rs_summary__v1() -%}
{%- raw -%}
Summarize the following text in one short sentence.

Text:
{{ input }}
{%- endraw -%}
{%- endmacro %}


{% macro prompt__rs_signal__v1() -%}
{%- raw -%}
Classify the text below into exactly one signal label.

Text:
{{ input }}
{%- endraw -%}
{%- endmacro %}

{% macro schema__rs_signal__v1() -%}
{%- raw -%}
{"type":"object","properties":{"signal":{"type":"string","enum":["bug","sales","positive","other"]}},"required":["signal"]}
{%- endraw -%}
{%- endmacro %}


{% macro prompt__rs_extract__v1() -%}
{%- raw -%}
Extract structured fields from the text below. Quote the evidence verbatim.

Text:
{{ input }}
{%- endraw -%}
{%- endmacro %}

{% macro schema__rs_extract__v1() -%}
{%- raw -%}
{"type":"object","properties":{"topic":{"type":"string"},"evidence":{"type":"string"}},"required":["topic"]}
{%- endraw -%}
{%- endmacro %}

{#-
  text(ai_result) -> the plain generated TEXT from an UNSTRUCTURED generate call (one with
  no output_schema), normalized across engines. Snowflake AI_COMPLETE and Databricks ai_query
  already return a string, but BigQuery AI.GENERATE returns a STRUCT whose text is under `.result`;
  this hides that difference so `text(generate('x'))` yields text everywhere.

  For a STRUCTURED result (output_schema passed), use field to pull individual typed fields.
  LIVE-VALIDATION DEFERRED on cloud engines.
-#}
{% macro text(ai_result) -%}
    {{ return(adapter.dispatch('text', 'dbt_context_engineering')(ai_result)) }}
{%- endmacro %}

{#- default (duckdb, Snowflake, Databricks): the result is already the text. -#}
{% macro default__text(ai_result) -%}
    {{ ai_result }}
{%- endmacro %}

{#- BigQuery AI.GENERATE returns STRUCT<result STRING, full_response JSON, status STRING>.
    Parenthesize so `.result` works whether the operand is a column or the AI.GENERATE call itself. -#}
{% macro bigquery__text(ai_result) -%}
    ({{ ai_result }}).result
{%- endmacro %}

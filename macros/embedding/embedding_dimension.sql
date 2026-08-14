{#-
  embedding_dimension(vector_expression) -> a SQL expression: the length of the vector array,
  observed from the actual value, not the configured/requested dimension.

  Per ADR-0023, this must be OBSERVED from the response, never the value
  you asked for, or a Matryoshka-style truncation config silently changes the vector while this
  column keeps agreeing with your (wrong) intent. Pass the embed() call's own result expression
  here, not a literal.

  Divergence: every engine names array length differently. All four dispatch branches
  (array_length/len on duckdb, array_size on Snowflake, size on Databricks, array_length on
  BigQuery) are confirmed live against a real connection on a literal array.
-#}

{% macro embedding_dimension(vector_expression) -%}
    {{ return(adapter.dispatch('embedding_dimension', 'dbt_context_engineering')(vector_expression)) }}
{%- endmacro %}

{#- default: duckdb. -#}
{% macro default__embedding_dimension(vector_expression) -%}
    array_length({{ vector_expression }})
{%- endmacro %}

{% macro snowflake__embedding_dimension(vector_expression) -%}
    array_size({{ vector_expression }})
{%- endmacro %}

{#- Spark/Databricks: size() is the standard array-length function. -#}
{% macro databricks__embedding_dimension(vector_expression) -%}
    size({{ vector_expression }})
{%- endmacro %}

{% macro bigquery__embedding_dimension(vector_expression) -%}
    array_length({{ vector_expression }})
{%- endmacro %}

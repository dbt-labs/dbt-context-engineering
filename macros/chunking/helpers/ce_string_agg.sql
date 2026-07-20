{#-
  ce_string_agg(expr, sep, order_expr) -> ordered string concatenation of expr, sequenced by
  order_expr, joined with sep.

  Divergence helper for ce_chunk (spec §5.3 portability note). `sep` is embedded as a literal;
  the default join separator is a real newline character, which is a valid literal on every
  target engine.
-#}

{% macro ce_string_agg(expr, sep, order_expr) -%}
    {{ return(adapter.dispatch('ce_string_agg', 'dbt_context_engineering')(expr, sep, order_expr)) }}
{%- endmacro %}

{#- default: ANSI ordered string_agg (duckdb, postgres, and the local deterministic-test engine). -#}
{% macro default__ce_string_agg(expr, sep, order_expr) -%}
    string_agg({{ expr }}, '{{ sep }}' order by {{ order_expr }})
{%- endmacro %}

{% macro snowflake__ce_string_agg(expr, sep, order_expr) -%}
    listagg({{ expr }}, '{{ sep }}') within group (order by {{ order_expr }})
{%- endmacro %}

{#- BigQuery rejects raw newlines in a single-quoted literal, so escape them (\n); BigQuery
    processes the escape, and STRING_AGG's delimiter must be a literal (not chr(10)). -#}
{% macro bigquery__ce_string_agg(expr, sep, order_expr) -%}
    string_agg({{ expr }}, '{{ sep | replace("'", "''") | replace("\n", "\\n") }}' order by {{ order_expr }})
{%- endmacro %}

{#- Spark/Databricks: no ordered string agg, so sort a struct of (order_key, value), project
    the value, and array_join. -#}
{% macro databricks__ce_string_agg(expr, sep, order_expr) -%}
    array_join(transform(array_sort(collect_list(struct({{ order_expr }} as _o, {{ expr }} as _v))), x -> x._v), '{{ sep }}')
{%- endmacro %}

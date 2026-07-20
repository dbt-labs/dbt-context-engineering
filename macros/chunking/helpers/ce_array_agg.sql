{#-
  ce_array_agg(expr, order_expr) -> ordered ARRAY aggregation of expr, sequenced by order_expr.

  Divergence helper for ce_chunk (spec §5.3 portability note). Ordered aggregation is one of the
  few places chunking SQL genuinely diverges per engine; the rest of ce_chunk is shared.
-#}

{% macro ce_array_agg(expr, order_expr) -%}
    {{ return(adapter.dispatch('ce_array_agg', 'dbt_context_engineering')(expr, order_expr)) }}
{%- endmacro %}

{#- default: ANSI ordered array_agg (duckdb, postgres, and the local deterministic-test engine). -#}
{% macro default__ce_array_agg(expr, order_expr) -%}
    array_agg({{ expr }} order by {{ order_expr }})
{%- endmacro %}

{% macro snowflake__ce_array_agg(expr, order_expr) -%}
    array_agg({{ expr }}) within group (order by {{ order_expr }})
{%- endmacro %}

{% macro bigquery__ce_array_agg(expr, order_expr) -%}
    array_agg({{ expr }} order by {{ order_expr }})
{%- endmacro %}

{#- Spark/Databricks: collect_list ordering is non-deterministic, so sort a struct of
    (order_key, value) and project the value back out. -#}
{% macro databricks__ce_array_agg(expr, order_expr) -%}
    transform(array_sort(collect_list(struct({{ order_expr }} as _o, {{ expr }} as _v))), x -> x._v)
{%- endmacro %}

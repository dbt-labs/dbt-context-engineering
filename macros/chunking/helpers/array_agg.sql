{#-
  array_agg(expr, order_expr) -> ordered ARRAY aggregation of expr, sequenced by order_expr.

  Divergence helper for chunk (spec §5.3 portability note). Ordered aggregation is one of the
  few places chunking SQL genuinely diverges per engine; the rest of chunk is shared.
-#}

{% macro array_agg(expr, order_expr) -%}
    {{ return(adapter.dispatch('array_agg', 'dbt_context_engineering')(expr, order_expr)) }}
{%- endmacro %}

{#- default: ANSI ordered array_agg (duckdb, postgres, and the local deterministic-test engine). -#}
{% macro default__array_agg(expr, order_expr) -%}
    array_agg({{ expr }} order by {{ order_expr }})
{%- endmacro %}

{% macro snowflake__array_agg(expr, order_expr) -%}
    array_agg({{ expr }}) within group (order by {{ order_expr }})
{%- endmacro %}

{% macro bigquery__array_agg(expr, order_expr) -%}
    array_agg({{ expr }} order by {{ order_expr }})
{%- endmacro %}

{#- Spark/Databricks: collect_list ordering is non-deterministic, so sort a struct of
    (order_key, value) and project the value back out. -#}
{% macro databricks__array_agg(expr, order_expr) -%}
    transform(array_sort(collect_list(struct({{ order_expr }} as _o, {{ expr }} as _v))), x -> x._v)
{%- endmacro %}

{#- Redshift has NO ARRAY_AGG and no group-level array constructor, so build the ordered array as a
    SUPER value: LISTAGG the JSON-encoded, ORDER-BY-sequenced elements into a '[...]' string and
    JSON_PARSE it. Elements are emitted as JSON STRINGS (every engine else keeps the id's native
    type) — a documented, acceptable divergence for source_rows, which is lineage over identifiers;
    chunk itself already casts ids to string for chunk_id. Quote/escape via chr() (34='"', 92='\')
    so no backslash/quote string literal appears here — side-stepping the standard_conforming_strings
    ambiguity str_literal otherwise rides on. LISTAGG's 64KB per-group cap applies (source_rows is
    one entry per unit in a chunk — small). -#}
{% macro redshift__array_agg(expr, order_expr) -%}
    json_parse('[' || listagg(
        chr(34) || replace(replace(cast({{ expr }} as varchar), chr(92), chr(92) || chr(92)), chr(34), chr(92) || chr(34)) || chr(34),
        ','
    ) within group (order by {{ order_expr }}) || ']')
{%- endmacro %}

{#-
  row_value_not_in(columns, relation) -> a SQL boolean expression: does the current row's tuple of
  `columns` NOT appear anywhere in `relation`'s same columns?
    (col1, col2, ...) not in (select col1, col2, ... from relation)

  Backs incremental_delta_predicate's content_hash_column argument. duckdb, Snowflake, and
  Databricks all accept the plain form above. BigQuery does not: "Subquery of type IN must have
  only one output column." It needs the subquery's SELECT list wrapped as a single tuple,
  `select (col1, col2, ...) from relation`, and that wrapped form is rejected in turn by both
  Snowflake (a database error) and Databricks (a struct/array length mismatch). See ADR-0023 for
  the reasoning behind this shape.
-#}

{% macro row_value_not_in(columns, relation) -%}
    {{ return(adapter.dispatch('row_value_not_in', 'dbt_context_engineering')(columns, relation)) }}
{%- endmacro %}

{#- default: duckdb, Snowflake, Databricks all accept the plain row-value form. -#}
{% macro default__row_value_not_in(columns, relation) -%}
    ({{ columns | join(', ') }}) not in (select {{ columns | join(', ') }} from {{ relation }})
{%- endmacro %}

{#- BigQuery requires the subquery's own output wrapped as a single tuple. -#}
{% macro bigquery__row_value_not_in(columns, relation) -%}
    ({{ columns | join(', ') }}) not in (select ({{ columns | join(', ') }}) from {{ relation }})
{%- endmacro %}

{#- Redshift supports NEITHER the plain row-value form NOR BigQuery's wrapped tuple — it has no
    multi-column/row-constructor IN at all. Rewrite as a correlated NOT EXISTS: the inner alias'd
    columns equal the outer row's same-named columns, true when no matching row exists. NULL
    semantics differ slightly from NOT IN (a null key here reads as "no match" -> dirty/reprocess
    rather than NOT IN's "unknown"), which is the safe direction for the delta check and does not
    arise in practice — the only caller (chunk's incremental delta) compares partition_key +
    partition_hash, both non-null when the predicate is applied. -#}
{% macro redshift__row_value_not_in(columns, relation) -%}
    not exists (select 1 from {{ relation }} _ce_rvni where {% for c in columns %}{% if not loop.first %} and {% endif %}_ce_rvni.{{ c }} = {{ c }}{% endfor %})
{%- endmacro %}

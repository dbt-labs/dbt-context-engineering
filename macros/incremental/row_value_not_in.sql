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

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
    multi-column/row-constructor IN at all. A correlated NOT EXISTS is a TRAP here: the inner
    relation's columns share the outer row's column names (e.g. chunk_id, content_hash on both
    sides), so an unqualified `col` in the correlated predicate binds to the INNER row, not the
    outer one. The predicate then compares each inner row to itself and NOT EXISTS is false for any
    non-empty table, so a changed row is never flagged — exactly the frozen-stale-value failure
    ADR-0023 exists to prevent (a new key still arrives via the `unique_key not in (...)` branch
    incremental_delta_predicate OR's this onto, which is why only the content-hash half breaks).
    Both callers hit this: incremental_delta_predicate's content_hash_column delta AND chunk's
    partition delta.

    Keep ADR-0023's NON-CORRELATED NOT IN by collapsing the tuple into one comparable key on both
    sides — md5 of the '|'-joined, null-coalesced columns — so a single-column IN suffices and no
    outer column can be shadowed. (Keys/hashes here contain no '|', so the join is unambiguous;
    md5 collision is negligible.) -#}
{% macro redshift__row_value_not_in(columns, relation) -%}
    {%- set _parts = [] -%}
    {%- for c in columns -%}{%- do _parts.append("coalesce(cast(" ~ c ~ " as varchar), '')") -%}{%- endfor -%}
    {%- set _key = "md5(" ~ (_parts | join(" || '|' || ")) ~ ")" -%}
    {{ _key }} not in (select {{ _key }} from {{ relation }})
{%- endmacro %}

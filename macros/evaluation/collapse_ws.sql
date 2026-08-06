{#-
  collapse_ws(expr) -> a SQL expression that trims `expr` and collapses every run of
  whitespace to a single space. Divergence helper for text normalization (see norm_text).

  regexp_replace diverges: duckdb needs an explicit 'g' (global) flag or it replaces only the
  first match, and its 4th arg IS that flag; Snowflake's 4th positional arg is a START POSITION
  (integer), so the duckdb form is unsafe there — Snowflake/Databricks replace all by default;
  BigQuery needs a raw string for the `\s` escape. Each engine gets its own impl.
-#}

{% macro collapse_ws(expr) -%}
    {{ return(adapter.dispatch('collapse_ws', 'dbt_context_engineering')(expr)) }}
{%- endmacro %}

{#- default = duckdb: needs the 'g' flag to replace all matches. -#}
{% macro default__collapse_ws(expr) -%}
    regexp_replace(trim({{ expr }}), '\s+', ' ', 'g')
{%- endmacro %}

{% macro snowflake__collapse_ws(expr) -%}
    regexp_replace(trim({{ expr }}), '\\s+', ' ')
{%- endmacro %}

{% macro databricks__collapse_ws(expr) -%}
    regexp_replace(trim({{ expr }}), '\\s+', ' ')
{%- endmacro %}

{% macro bigquery__collapse_ws(expr) -%}
    regexp_replace(trim({{ expr }}), r'\s+', ' ')
{%- endmacro %}

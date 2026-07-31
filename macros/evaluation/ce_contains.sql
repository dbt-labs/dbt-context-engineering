{#-
  ce_contains(haystack, needle) -> a boolean SQL expression: does `needle` appear as a substring
  of `haystack`? Case-sensitive, exact. Divergence helper for the evaluation tests (ce_grounded).

  Containment is one of the few string primitives that genuinely diverges: ANSI
  `POSITION(needle IN haystack)` covers duckdb / Snowflake / Databricks, but BigQuery has no such
  form and uses STRPOS. Isolated here so callers stay portable (adapter-dispatch principle).
-#}

{% macro ce_contains(haystack, needle) -%}
    {{ return(adapter.dispatch('ce_contains', 'dbt_context_engineering')(haystack, needle)) }}
{%- endmacro %}

{#- default: ANSI POSITION(substring IN string) — duckdb, Snowflake, Databricks all support it. -#}
{% macro default__ce_contains(haystack, needle) -%}
    position({{ needle }} in {{ haystack }}) > 0
{%- endmacro %}

{#- BigQuery has no POSITION(x IN y); STRPOS(string, substring) returns 1-based index, 0 if absent. -#}
{% macro bigquery__ce_contains(haystack, needle) -%}
    strpos({{ haystack }}, {{ needle }}) > 0
{%- endmacro %}

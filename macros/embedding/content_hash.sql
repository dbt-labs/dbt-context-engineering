{#-
  content_hash(text_expression) -> a SQL expression: SHA-256 of text_expression, as a lowercase
  hex string, on every engine.

  The re-embed cache key's text-change half (see ADR-0023). Hash the exact
  string handed to embed(), after chunking, after any attach_metadata in_text prepending, not a
  raw source column. A change to assembly logic that doesn't touch the final string should not go
  undetected, and a change to the raw column that doesn't survive assembly should not trigger a
  pointless re-embed. Compared against the stored value inside incremental_delta_predicate's
  optional content_hash_column argument.

  Divergence: Snowflake/Databricks SHA2 returns a hex string directly. BigQuery's SHA256 returns
  BYTES and needs TO_HEX to match. duckdb's sha256 already returns a hex VARCHAR, so it needs no
  wrapping, the only primitive in this package where the "default" (duckdb) case needs zero
  adaptation from the underlying builtin. All four dispatch branches are confirmed live, matching
  the known SHA-256 of a fixed string exactly on every engine.
-#}

{% macro content_hash(text_expression) -%}
    {{ return(adapter.dispatch('content_hash', 'dbt_context_engineering')(text_expression)) }}
{%- endmacro %}

{#- default: duckdb's sha256 already returns a lowercase hex VARCHAR. -#}
{% macro default__content_hash(text_expression) -%}
    sha256({{ text_expression }})
{%- endmacro %}

{% macro snowflake__content_hash(text_expression) -%}
    sha2({{ text_expression }}, 256)
{%- endmacro %}

{% macro databricks__content_hash(text_expression) -%}
    sha2({{ text_expression }}, 256)
{%- endmacro %}

{#- BigQuery's SHA256 returns BYTES; TO_HEX matches the hex-string shape every other engine returns. -#}
{% macro bigquery__content_hash(text_expression) -%}
    to_hex(sha256({{ text_expression }}))
{%- endmacro %}

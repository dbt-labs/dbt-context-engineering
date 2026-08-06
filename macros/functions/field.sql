{#-
  field(ai_result, field, as_type=none) -> a portable expression that pulls one named field
  out of a STRUCTURED AI result and casts it. This closes the output half of the portability
  promise: generate(..., output_schema)/extract return a different SHAPE per engine
  (Snowflake VARIANT object, Databricks JSON string, BigQuery STRUCT), and this normalizes reading
  a field back out so downstream SQL — and conforms_to_schema — see a plain typed scalar.

  Pair with the wrappers:
    select
      {{ dbt_context_engineering.field('signal_raw', 'signal') }}   as signal,
      {{ dbt_context_engineering.field('signal_raw', 'evidence') }} as evidence
    from {{ ref('signals') }}          -- signal_raw = generate(..., output_schema=schema(...))

  `as_type` defaults to the engine's string type; pass a SQL type (e.g. dbt.type_int()) for others.
  Use text for an UNSTRUCTURED (no output_schema) generation. LIVE-VALIDATION DEFERRED on cloud
  engines; the default (JSON-string) path is validated on duckdb.
-#}
{% macro field(ai_result, field, as_type=none) -%}
    {%- set t = as_type if as_type is not none else dbt.type_string() -%}
    {{ return(adapter.dispatch('field', 'dbt_context_engineering')(ai_result, field, t)) }}
{%- endmacro %}

{#- default = duckdb + baseline for any engine whose result is a JSON string. -#}
{% macro default__field(ai_result, field, as_type) -%}
    cast(json_extract_string({{ ai_result }}, '$.{{ field }}') as {{ as_type }})
{%- endmacro %}

{#- Databricks ai_query structured output returns a JSON STRING. -#}
{% macro databricks__field(ai_result, field, as_type) -%}
    cast(get_json_object({{ ai_result }}, '$.{{ field }}') as {{ as_type }})
{%- endmacro %}

{#- Snowflake AI_COMPLETE(response_format=…) / AI_EXTRACT return a VARIANT OBJECT — path-access it.
    Parenthesize the operand so a function-call result (not just a column) is field-addressable. -#}
{% macro snowflake__field(ai_result, field, as_type) -%}
    cast(({{ ai_result }}):{{ field }} as {{ as_type }})
{%- endmacro %}

{#- BigQuery AI.GENERATE(output_schema=…) returns a STRUCT whose fields are the schema properties.
    Parenthesize so field access works whether the operand is a column or a function call. -#}
{% macro bigquery__field(ai_result, field, as_type) -%}
    cast(({{ ai_result }}).{{ field }} as {{ as_type }})
{%- endmacro %}

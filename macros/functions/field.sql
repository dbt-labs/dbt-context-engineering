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
  Use text for an UNSTRUCTURED (no output_schema) generation. The default (JSON-string)
  path is executed on duckdb. The Snowflake VARIANT, Databricks JSON-string and BigQuery STRUCT
  branches were executed live by assert_flatten_conforms and assert_extract_conforms in the
  2026-09-25 cloud pass, and the Redshift branch in the Redshift pass. The typed-cast probe
  (assert_typed_field_casts) covers integer, number and boolean casts on all four engines.
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

{#- Redshift's Bedrock text UDF returns a JSON STRING (there is no structured/response_format path),
    so read a top-level field with JSON_EXTRACT_PATH_TEXT. Pass each path element as its own quoted
    arg (not a '$.f' JSONPath). Best-effort: if the model didn't return valid JSON this yields null,
    which is the intended signal, not a hard error. The trailing `true` is JSON_EXTRACT_PATH_TEXT's
    null_if_invalid argument: without it Redshift raises "JSON parsing error" on a reply wrapped in
    code fences or prose, which would fail the whole build instead of yielding null. A value that
    parses but cannot be cast to the target type (for example "seven" to integer) still raises. -#}
{% macro redshift__field(ai_result, field, as_type) -%}
    {#- Redshift cannot cast a text or varchar column to BOOLEAN ("cannot cast type text to
        boolean", then "character varying to boolean", found by the typed-cast probe). Booleans
        are mapped from the JSON literal instead. Every other target type casts directly. -#}
    {%- if 'bool' in (as_type | string | lower) -%}
    case lower(json_extract_path_text({{ ai_result }}, '{{ field }}', true))
        when 'true' then true
        when 'false' then false
    end
    {%- else -%}
    cast(json_extract_path_text({{ ai_result }}, '{{ field }}', true) as {{ as_type }})
    {%- endif -%}
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

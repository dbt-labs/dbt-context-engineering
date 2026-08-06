{#-
  bq_output_schema(json_schema) -> BigQuery output_schema STRING.

  BigQuery's AI.GENERATE / AI.GENERATE_TABLE take output_schema as a comma-separated list of
  `name TYPE [OPTIONS(description=...)]` (NOT a JSON schema, unlike Snowflake/Databricks). This
  converts the package's single JSON schema into that form. Note: JSON `enum` has no BigQuery
  output_schema equivalent, so an enum field becomes plain STRING (the prompt still constrains the
  labels). Single-line output — safe to triple-quote in the SQL.
-#}
{% macro bq_output_schema(json_schema) -%}
    {%- set sd = fromjson(json_schema) -%}
    {%- set typemap = {'string': 'STRING', 'integer': 'INT64', 'number': 'FLOAT64', 'boolean': 'BOOL'} -%}
    {%- set fields = [] -%}
    {%- for name, prop in (sd.get('properties', {})).items() -%}
        {%- set bqt = typemap.get(prop.get('type', 'string'), 'STRING') -%}
        {%- set desc = prop.get('description') -%}
        {%- if desc -%}
            {%- do fields.append(name ~ ' ' ~ bqt ~ ' OPTIONS(description="' ~ (desc | replace('"', '\\"')) ~ '")') -%}
        {%- else -%}
            {%- do fields.append(name ~ ' ' ~ bqt) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- if (fields | length) == 0 -%}
        {{ exceptions.raise_compiler_error("bq_output_schema: schema has no properties to convert.") }}
    {%- endif -%}
    {{- return(fields | join(', ')) -}}
{%- endmacro %}

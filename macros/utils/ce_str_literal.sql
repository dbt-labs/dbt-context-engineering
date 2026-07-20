{#-
  ce_str_literal(s) -> a PORTABLE SQL string-literal expression for s.

  BigQuery rejects a raw newline inside a single-quoted literal (Snowflake/duckdb accept it), so
  newlines are emitted as chr(10) concatenation, which is valid on all engines:
      "a\nb"  ->  'a' || chr(10) || 'b'
  Single quotes are SQL-escaped. Used wherever multi-line text is embedded as a literal
  (e.g. ce_render_prompt).
-#}
{% macro ce_str_literal(s) -%}
    {%- set parts = s.split('\n') -%}
    {%- set out = [] -%}
    {%- for p in parts -%}
        {%- do out.append("'" ~ (p | replace("'", "''")) ~ "'") -%}
    {%- endfor -%}
    {{- return(out | join(' || chr(10) || ')) -}}
{%- endmacro %}

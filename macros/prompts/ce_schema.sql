{#-
  ce_schema(name, version) -> output JSON schema (string) for that name/version, as a
  compile-time literal.

  D4 = macro library (see ce_prompt.sql, DECISIONS.md). Each schema version is a macro
  `default__ce_schema__<name>__<version>()` beside its prompt under prompts/. The schema is the
  taxonomy: enums are the allowed labels, and it should require an evidence/quote field so each
  extracted fact carries its source text. Resolved to a literal via adapter.dispatch.
-#}
{% macro ce_schema(name, version) -%}
    {%- if name is none or version is none -%}
        {{ exceptions.raise_compiler_error("ce_schema: name and version are both required.") }}
    {%- endif -%}
    {%- set fq = 'ce_schema__' ~ name ~ '__' ~ version -%}
    {%- if fq not in dbt_context_engineering -%}
        {{ exceptions.raise_compiler_error(
            "ce_schema: schema '" ~ name ~ "' version '" ~ version ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() under prompts/.") }}
    {%- endif -%}
    {{- return(dbt_context_engineering[fq]()) -}}
{%- endmacro %}

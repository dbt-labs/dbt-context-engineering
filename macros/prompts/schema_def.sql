{#-
  schema(name, version) -> output JSON schema (string) for that name/version, as a
  compile-time literal.

  Macro library, ADR-0001 (see prompt.sql). Each schema version is a macro
  `schema__<name>__<version>()` beside its prompt on a macro path. The schema is the taxonomy:
  enums are the allowed labels, and it should require an evidence/quote field so each extracted fact
  carries its source text. Like prompt, schemas may live in the calling project OR in this
  package — resolved from dbt's flat macro namespace (calling project wins), with this package's
  namespace as a fallback.
-#}
{% macro schema_def(name, version) -%}
    {%- if name is none or version is none -%}
        {{ exceptions.raise_compiler_error("schema: name and version are both required.") }}
    {%- endif -%}
    {%- set fq = 'schema__' ~ name ~ '__' ~ version -%}
    {#- flat namespace first (calling project + packages), then this package as a fallback -#}
    {%- set macro = context.get(fq) if context is defined else none -%}
    {%- if macro is none and fq in dbt_context_engineering -%}
        {%- set macro = dbt_context_engineering[fq] -%}
    {%- endif -%}
    {%- if macro is none -%}
        {{ exceptions.raise_compiler_error(
            "schema: schema '" ~ name ~ "' version '" ~ version ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() on a macro path (in your project or this package).") }}
    {%- endif -%}
    {{- return(macro()) -}}
{%- endmacro %}

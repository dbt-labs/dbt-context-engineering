{#-
  schema(name, version) -> output JSON schema (string) for that name/version, as a
  compile-time literal.

  Macro library, ADR-0001 (see prompt.sql), resolver contract narrowed by ADR-0032. Each schema
  version is a macro `schema__<name>__<version>()` beside its prompt on a macro path **in the
  calling project**. Like prompt, a package must never rely on this resolver to expose its own
  schemas: dbt Fusion cannot resolve a package's own namespace from within a macro defined in that
  same package, and a schema's taxonomy is inherently tied to one business anyway, so it belongs in
  the consuming project, not a shared package.
-#}
{% macro schema_def(name, version) -%}
    {%- if name is none or version is none -%}
        {{ exceptions.raise_compiler_error("schema: name and version are both required.") }}
    {%- endif -%}
    {%- set fq = 'schema__' ~ name ~ '__' ~ version -%}
    {%- set macro = context.get(fq) if context is defined else none -%}
    {%- if macro is none -%}
        {{ exceptions.raise_compiler_error(
            "schema: schema '" ~ name ~ "' version '" ~ version ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() on a macro path in your project.") }}
    {%- endif -%}
    {{- return(macro()) -}}
{%- endmacro %}

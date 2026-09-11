{#-
  prompt(name, version) -> prompt text for that name/version, as a compile-time literal.

  Macro library, ADR-0001, resolver contract narrowed by ADR-0032. Each prompt version is a macro
  `prompt__<name>__<version>()` on a macro path **in the calling project**. The resolver looks the
  name up in dbt's flat macro namespace (`context`), which is scoped to the calling project. A
  package must never rely on this resolver to expose its own prompts: dbt Fusion cannot resolve a
  package's own namespace from within a macro defined in that same package (confirmed; see
  ADR-0032), and a prompt is inherently tied to one business's taxonomy anyway, so it belongs in the
  consuming project, not a shared package. A package wanting to expose reusable Jinja logic should
  do so as a directly-callable, package-qualified macro instead, which Fusion resolves correctly.
  The resolved text is embedded in the compiled SQL for auditability. Versions are explicit and
  required, no implicit "latest".
-#}
{% macro prompt(name, version) -%}
    {%- if name is none or version is none -%}
        {{ exceptions.raise_compiler_error("prompt: name and version are both required (no implicit 'latest').") }}
    {%- endif -%}
    {%- set fq = 'prompt__' ~ name ~ '__' ~ version -%}
    {%- set macro = context.get(fq) if context is defined else none -%}
    {%- if macro is none -%}
        {{ exceptions.raise_compiler_error(
            "prompt: prompt '" ~ name ~ "' version '" ~ version ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() on a macro path in your project.") }}
    {%- endif -%}
    {{- return(macro()) -}}
{%- endmacro %}

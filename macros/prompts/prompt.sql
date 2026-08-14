{#-
  prompt(name, version) -> prompt text for that name/version, as a compile-time literal.

  Macro library, ADR-0001. Each prompt version is a macro `prompt__<name>__<version>()`
  on a macro path. Prompts may live EITHER in the calling dbt project OR in this package: the
  resolver looks the name up in dbt's flat macro namespace (`context`), which contains both, with
  the calling project winning on a name collision (so a project can override a packaged prompt). If
  `context` is unavailable in a given render mode, it falls back to this package's own namespace.
  The resolved text is embedded in the compiled SQL for auditability. Versions are explicit and
  required — no implicit "latest".
-#}
{% macro prompt(name, version) -%}
    {%- if name is none or version is none -%}
        {{ exceptions.raise_compiler_error("prompt: name and version are both required (no implicit 'latest').") }}
    {%- endif -%}
    {%- set fq = 'prompt__' ~ name ~ '__' ~ version -%}
    {#- flat namespace first (calling project + packages), then this package as a fallback -#}
    {%- set macro = context.get(fq) if context is defined else none -%}
    {%- if macro is none and fq in dbt_context_engineering -%}
        {%- set macro = dbt_context_engineering[fq] -%}
    {%- endif -%}
    {%- if macro is none -%}
        {{ exceptions.raise_compiler_error(
            "prompt: prompt '" ~ name ~ "' version '" ~ version ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() on a macro path (in your project or this package).") }}
    {%- endif -%}
    {{- return(macro()) -}}
{%- endmacro %}

{#-
  ce_prompt(name, version) -> prompt text for that name/version, as a compile-time literal.

  D4 = macro library (DECISIONS.md). Each prompt version is a macro
  `default__ce_prompt__<name>__<version>()` under prompts/ (a macro-path). This resolver reaches
  it via adapter.dispatch (proven to resolve cross-package), so the resolved text is embedded in
  the compiled SQL for auditability. Versions are explicit and required — no implicit "latest".
-#}
{% macro ce_prompt(name, version) -%}
    {%- if name is none or version is none -%}
        {{ exceptions.raise_compiler_error("ce_prompt: name and version are both required (no implicit 'latest').") }}
    {%- endif -%}
    {%- set fq = 'ce_prompt__' ~ name ~ '__' ~ version -%}
    {%- if fq not in dbt_context_engineering -%}
        {{ exceptions.raise_compiler_error(
            "ce_prompt: prompt '" ~ name ~ "' version '" ~ version ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() under prompts/.") }}
    {%- endif -%}
    {{- return(dbt_context_engineering[fq]()) -}}
{%- endmacro %}

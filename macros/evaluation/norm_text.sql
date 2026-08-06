{#-
  norm_text(expr, ignore_case=false, normalize_whitespace=false) -> a SQL expression applying
  the requested normalizations to `expr`. Both are documented, opt-in knobs (config over
  inference) so grounding can tolerate the casing/whitespace drift an LLM introduces when it
  quotes source text, without silently loosening exact-match grounding.

  Whitespace collapse dispatches per engine (collapse_ws); lower() is portable everywhere.
-#}
{% macro norm_text(expr, ignore_case=false, normalize_whitespace=false) -%}
    {%- set inner = expr -%}
    {%- if normalize_whitespace -%}
        {%- set inner = dbt_context_engineering.collapse_ws(inner) -%}
    {%- endif -%}
    {%- if ignore_case -%}
        {%- set inner = 'lower(' ~ inner ~ ')' -%}
    {%- endif -%}
    {{- return(inner) -}}
{%- endmacro %}

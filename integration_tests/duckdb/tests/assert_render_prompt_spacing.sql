{#- render_prompt must substitute the input column for {{ input }} regardless of interior whitespace.
    A stray/missing space must NOT silently skip substitution (which sends the literal "{{input}}" to
    the model). Compile-time assertion across spacing variants; raises on regression. Guards finding #2. -#}
{%- set col = 'utterance_text' -%}
{%- set errs = [] -%}
{%- for v in ['{{input}}', '{{ input }}', '{{  input  }}'] -%}
    {%- set rendered = dbt_context_engineering.render_prompt('Text: ' ~ v, col) -%}
    {%- if col not in rendered -%}
        {%- do errs.append("no substitution for '" ~ v ~ "' -> " ~ rendered) -%}
    {%- endif -%}
    {%- if 'input' in rendered -%}
        {%- do errs.append("placeholder left unsubstituted for '" ~ v ~ "' -> " ~ rendered) -%}
    {%- endif -%}
{%- endfor -%}
{%- if (errs | length) > 0 -%}
    {{ exceptions.raise_compiler_error('render_prompt spacing regression: ' ~ (errs | join(' || '))) }}
{%- endif -%}
select 1 as ok where 1 = 0

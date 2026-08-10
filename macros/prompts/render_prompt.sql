{#-
  render_prompt(prompt, input_column) -> a SQL string expression that is the prompt template
  with its {{ input }} placeholder replaced by the input column reference.

  The resolved prompt text (from prompt) is a compile-time literal; this splits it on the
  {{ input }} placeholder and stitches the parts back together as a portable SQL concatenation:
      'literal part before' || <input_column> || 'literal part after'
  str_literal handles per-engine quoting/escaping (quotes, backslashes, newlines). If the template
  has no placeholder, the result is just the quoted literal (a constant prompt). Used by every wrapper.

  Placeholder matching is WHITESPACE-TOLERANT: {{input}}, {{ input }}, and {{  input  }} all match
  the same, because the placeholder is authored by hand in a prompt macro and a stray space must not
  silently skip substitution (which would send the literal text "{{input}}" to the model and never
  inject the row's value). The match is a regex on `{{\s*input\s*}}`, brace-escaped.
-#}
{% macro render_prompt(prompt, input_column) -%}
    {%- if prompt is none -%}
        {{ exceptions.raise_compiler_error(
            "render_prompt: prompt is none. generate/classify/extract all need a resolved prompt — "
            ~ "pass prompt=dbt_context_engineering.prompt('<name>','<version>'). The input column is "
            ~ "injected via the prompt's {{ input }} placeholder, so a prompt is required even when the "
            ~ "output_schema alone defines the task.") }}
    {%- endif -%}
    {#- brace-escaped regex; raw so the backslashes reach modules.re as a literal pattern -#}
    {%- set pattern -%}{%- raw -%}\{\{\s*input\s*\}\}{%- endraw -%}{%- endset -%}
    {%- set has_placeholder = modules.re.search(pattern, prompt) is not none -%}
    {%- if has_placeholder and input_column is none -%}
        {{ exceptions.raise_compiler_error(
            "render_prompt: prompt has an {{ input }} placeholder but no input_column was given.") }}
    {%- endif -%}
    {%- set parts = modules.re.split(pattern, prompt) -%}
    {%- set tokens = [] -%}
    {%- for part in parts -%}
        {#- str_literal renders newlines portably (chr(10)) and escapes quotes/backslashes per engine -#}
        {%- if part != '' -%}{%- do tokens.append(dbt_context_engineering.str_literal(part)) -%}{%- endif -%}
        {%- if not loop.last -%}{%- do tokens.append(input_column) -%}{%- endif -%}
    {%- endfor -%}
    {%- if (tokens | length) == 0 -%}{%- do tokens.append("''") -%}{%- endif -%}
    {{- return(tokens | join(' || ')) -}}
{%- endmacro %}

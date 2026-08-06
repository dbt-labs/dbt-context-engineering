{#-
  render_prompt(prompt, input_column) -> a SQL string expression that is the prompt template
  with its {{ input }} placeholder replaced by the input column reference.

  The resolved prompt text (from prompt) is a compile-time literal; this splits it on the
  {{ input }} placeholder and stitches the parts back together as a portable SQL concatenation:
      'literal part before' || <input_column> || 'literal part after'
  Single quotes in the prompt are SQL-escaped. If the template has no placeholder, the result is
  just the quoted literal (a constant prompt). Used by every function wrapper.
-#}
{% macro render_prompt(prompt, input_column) -%}
    {%- set placeholder -%}{%- raw -%}{{ input }}{%- endraw -%}{%- endset -%}
    {%- if placeholder in prompt and input_column is none -%}
        {{ exceptions.raise_compiler_error(
            "render_prompt: prompt has a {{ input }} placeholder but no input_column was given.") }}
    {%- endif -%}
    {%- set parts = prompt.split(placeholder) -%}
    {%- set tokens = [] -%}
    {%- for part in parts -%}
        {#- str_literal renders newlines portably (chr(10)) — BigQuery rejects raw newlines in literals -#}
        {%- if part != '' -%}{%- do tokens.append(dbt_context_engineering.str_literal(part)) -%}{%- endif -%}
        {%- if not loop.last -%}{%- do tokens.append(input_column) -%}{%- endif -%}
    {%- endfor -%}
    {%- if (tokens | length) == 0 -%}{%- do tokens.append("''") -%}{%- endif -%}
    {{- return(tokens | join(' || ')) -}}
{%- endmacro %}

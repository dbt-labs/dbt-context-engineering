{#-
  estimate_tokens(text_expression) -> a SQL expression estimating tokens for the given text,
  with NO AI call. Heuristic: ceil(char_length / 4) (D5). The input-text term of
  estimate_call_tokens below. length() is portable across all target engines.
-#}
{% macro estimate_tokens(text_expression) -%}
    {{ return('ceil(length(' ~ text_expression ~ ') / 4.0)') }}
{%- endmacro %}


{#-
  estimate_call_tokens(input_column, prompt, output_schema, output_tokens) -> a SQL expression
  estimating the tokens ONE row's AI call is billed for, with NO AI call. Shared by guard_batch
  (pre-hook ceiling) and log_ai_run (logged est_tokens / est_cost).

  Three terms, summed per row:
  1. Input text: estimate_tokens(input_column). 0 when input_column is none.
  2. Prompt template and output schema: sent with EVERY row by generate/classify/extract, so they
     are billed once per row, not once per batch. A compile-time constant: the template's
     characters with its {{ input }} placeholder removed, plus the schema's characters, / 4. On
     BigQuery the enum block augment_prompt adds is counted too, because that is the text sent.
  3. Output allowance: output_tokens when passed, otherwise var('est_output_tokens_per_row'),
     otherwise var('max_output_tokens'). max_output_tokens is a cap, so falling back to it gives
     an upper bound: conservative for the guard, and it can overstate est_cost. 0 when none is set.

  Terms 2 and 3 apply only when prompt is passed (or output_tokens is passed explicitly). Without
  them the estimate is input-only, which is accurate for embed, but understates generate/classify/
  extract several-fold: measured on Snowflake extract, billed tokens ran ~6x the input-only
  estimate (ADR-0035). guard_batch and log_ai_run resolve prompt and output_schema from the model's
  meta.ai_prompt before calling this (resolve_call_prompt), so the body and hooks share one source.
-#}
{% macro estimate_call_tokens(input_column=none, prompt=none, output_schema=none, output_tokens=none) -%}
    {%- set input_expr = dbt_context_engineering.estimate_tokens(input_column) if input_column is not none else '0' -%}
    {%- set ns = namespace(per_row=0) -%}

    {%- if prompt is not none -%}
        {%- set sent = dbt_context_engineering.augment_prompt(prompt, output_schema) if target.type == 'bigquery' else prompt -%}
        {%- set pattern -%}{%- raw -%}\{\{\s*input\s*\}\}{%- endraw -%}{%- endset -%}
        {%- set template_chars = (modules.re.sub(pattern, '', sent) | length)
                                 + ((output_schema | length) if output_schema is not none else 0) -%}
        {%- set ns.per_row = ((template_chars / 4) | round(0, 'ceil') | int) -%}
    {%- endif -%}

    {%- if output_tokens is not none -%}
        {%- set ns.per_row = ns.per_row + (output_tokens | int) -%}
    {%- elif prompt is not none -%}
        {#- a var declared as null counts as set, so fall through on none explicitly -#}
        {%- set allowance = var('est_output_tokens_per_row', none) -%}
        {%- if allowance is none -%}{%- set allowance = var('max_output_tokens', none) -%}{%- endif -%}
        {%- set ns.per_row = ns.per_row + ((allowance or 0) | int) -%}
    {%- endif -%}

    {%- if ns.per_row == 0 -%}{{ return(input_expr) }}{%- endif -%}
    {{ return('(' ~ input_expr ~ ' + ' ~ ns.per_row ~ ')') }}
{%- endmacro %}

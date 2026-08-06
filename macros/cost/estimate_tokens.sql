{#-
  estimate_tokens(text_expression) -> a SQL expression estimating tokens for the given text,
  with NO AI call. Heuristic: ceil(char_length / 4) (D5). Shared by guard_batch (pre-hook
  ceiling) and log_ai_run (logged est_tokens). length() is portable across all target engines.
-#}
{% macro estimate_tokens(text_expression) -%}
    {{ return('ceil(length(' ~ text_expression ~ ') / 4.0)') }}
{%- endmacro %}

{#-
  ce_estimate_tokens(text_expression) -> a SQL expression estimating tokens for the given text,
  with NO AI call. Heuristic: ceil(char_length / 4) (D5). Shared by ce_guard_batch (pre-hook
  ceiling) and ce_log_ai_run (logged est_tokens). length() is portable across all target engines.
-#}
{% macro ce_estimate_tokens(text_expression) -%}
    {{ return('ceil(length(' ~ text_expression ~ ') / 4.0)') }}
{%- endmacro %}

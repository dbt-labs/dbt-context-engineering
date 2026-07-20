{#-
  ce_log_ai_run — post-hook that appends one row to ce_ai_run_log per AI model run (spec §5.4).

  Usage (post-hook on any AI model):
    {{ config(post_hook = "{{ ce_log_ai_run('classify', model_name='claude-3-5-sonnet',
                                            relation=ref('my_inputs'), input_column='text_col') }}") }}

  Args:
    function_name  which ce_ function issued the call (generate/classify/extract/embed). Required.
    model_name     the AI model used (the largest cost lever; always logged). Optional.
    relation       relation to size the batch from. Defaults to `this` (the built model).
    input_column   text column for the token estimate. If omitted, est_tokens/est_cost are null.

  est_cost = est_tokens / 1000 * var('ce_cost_per_1k_tokens') when both are available; otherwise
  null (corrected later by ce_cost_reconciliation against real usage).
-#}
{% macro ce_log_ai_run(function_name, model_name=none, relation=none, input_column=none) -%}
    {#- No execute-guard: this macro only BUILDS an insert statement (dbt runs it as the hook), so
        the ref() below must always render for dbt to infer the ce_ai_run_log dependency. -#}
    {%- set rel = relation if relation is not none else this -%}
    {%- set str_t = dbt.type_string() -%}
    {%- set model_sql = "'" ~ model_name ~ "'" if model_name is not none else "cast(null as " ~ str_t ~ ")" -%}
    {%- set price = var('ce_cost_per_1k_tokens', none) -%}

    {%- if input_column is not none -%}
        {%- set tokens_sql = "(select coalesce(sum(" ~ dbt_context_engineering.ce_estimate_tokens(input_column) ~ "), 0) from " ~ rel ~ ")" -%}
        {%- set cost_sql = (tokens_sql ~ " / 1000.0 * " ~ price) if price is not none else ("cast(null as " ~ dbt.type_numeric() ~ ")") -%}
    {%- else -%}
        {%- set tokens_sql = "cast(null as " ~ dbt.type_numeric() ~ ")" -%}
        {%- set cost_sql = "cast(null as " ~ dbt.type_numeric() ~ ")" -%}
    {%- endif -%}

    insert into {{ ref('ce_ai_run_log') }}
        (invocation_id, model_name, function_name, row_count, est_tokens, est_cost, run_at)
    select
        '{{ invocation_id }}',
        {{ model_sql }},
        '{{ function_name }}',
        {#- cast every value to the log column's type — BigQuery rejects implicit FLOAT64->NUMERIC etc. -#}
        cast((select count(*) from {{ rel }}) as {{ dbt.type_int() }}),
        cast({{ tokens_sql }} as {{ dbt.type_numeric() }}),
        cast({{ cost_sql }} as {{ dbt.type_numeric() }}),
        {#- cast to the column's type: Snowflake current_timestamp is TZ-aware but run_at is NTZ -#}
        cast({{ dbt.current_timestamp() }} as {{ dbt.type_timestamp() }})
{%- endmacro %}

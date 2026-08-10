{#-
  log_ai_run: appends one row to ai_run_log per AI model run (spec §5.4). Usable as either a
  pre_hook or a post_hook.

  Usage (unfiltered, logs the full relation; safe as either a pre_hook or post_hook):
    {{ config(post_hook = "{{ log_ai_run('classify', model_name='claude-3-5-sonnet',
                                            relation=ref('my_inputs'), input_column='text_col') }}") }}

  Usage on an INCREMENTAL model with `filter` (e.g. incremental_delta_predicate): use a
  PRE_HOOK, not a post_hook.
    {{ config(materialized='incremental', unique_key='doc_id',
       pre_hook = [
         "{{ guard_batch(ref('stg_docs'), 'body', filter=incremental_delta_predicate('doc_id')) }}",
         "{{ log_ai_run('embed', relation=ref('stg_docs'), input_column='body',
                          filter=incremental_delta_predicate('doc_id')) }}"
       ]) }}

  WARNING: do not pass a `filter` that references `this` (directly, or via
  incremental_delta_predicate, which expands to `<unique_key> not in (select <unique_key> from
  {{ this }})`) in a post_hook on an incremental model. By the time a post_hook fires, this run's
  merge has already landed the new rows into `this`, so that same "not in this" predicate now
  finds nothing: it logs row_count = 0 for a run that really processed rows. guard_batch and
  log_ai_run must run in the same hook phase relative to the merge, pre_hook, whenever `filter`
  is derived from `this`. Confirmed against a live incremental model: see dbt_gong's ADR-0006
  (github.com/fivetran/dbt_gong) for the reproduction.

  Args:
    function_name  which  function issued the call (generate/classify/extract/embed). Required.
    model_name     the AI model used (the largest cost lever; always logged). Optional.
    relation       relation to size the batch from. Defaults to `this` (the built model).
    input_column   text column for the token estimate. If omitted, est_tokens/est_cost are null.
    filter         optional SQL predicate scoping the count to the rows the run ACTUALLY processed.
                   On an incremental model the body only touches the delta, so without this the log
                   records the whole corpus every run (row_count/est_tokens/est_cost off by orders of
                   magnitude). Pass the SAME predicate the body uses — incremental_delta_predicate()
                   gives all three (body / guard_batch / here) one source of truth. Sizing from `this`
                   (the default) also requires that `input_column` exists in the model's OUTPUT — pass
                   relation=ref('<source>') when the source column isn't carried into the output. See
                   the WARNING above before using this on an incremental model.

  est_cost = est_tokens / 1000 * var('cost_per_1k_tokens') when both are available; otherwise
  null (left null when no price var is set).
-#}
{% macro log_ai_run(function_name, model_name=none, relation=none, input_column=none, filter=none) -%}
    {#- No execute-guard: this macro only BUILDS an insert statement (dbt runs it as the hook), so
        the ref() below must always render for dbt to infer the ai_run_log dependency. -#}
    {%- set rel = relation if relation is not none else this -%}
    {%- set str_t = dbt.type_string() -%}
    {%- set num_t = dbt.type_numeric() -%}
    {%- set model_sql = "'" ~ model_name ~ "'" if model_name is not none else "cast(null as " ~ str_t ~ ")" -%}
    {%- set price = var('cost_per_1k_tokens', none) -%}

    {#- Size the batch with a SINGLE scan of the relation (derived table _sz), then reference its
        columns below — count and token-sum are computed once, not once per output column. -#}
    {%- if input_column is not none -%}
        {%- set sz_select = "count(*) as _n, coalesce(sum(" ~ dbt_context_engineering.estimate_tokens(input_column) ~ "), 0) as _toks" -%}
        {%- set tokens_expr = "cast(_sz._toks as " ~ num_t ~ ")" -%}
        {%- set cost_expr = ("cast(_sz._toks / 1000.0 * " ~ price ~ " as " ~ num_t ~ ")") if price is not none else ("cast(null as " ~ num_t ~ ")") -%}
    {%- else -%}
        {%- set sz_select = "count(*) as _n" -%}
        {%- set tokens_expr = "cast(null as " ~ num_t ~ ")" -%}
        {%- set cost_expr = "cast(null as " ~ num_t ~ ")" -%}
    {%- endif -%}

    insert into {{ ref('ai_run_log') }}
        (invocation_id, model_name, function_name, row_count, est_tokens, est_cost, run_at)
    select
        '{{ invocation_id }}',
        {{ model_sql }},
        '{{ function_name }}',
        {#- cast every value to the log column's type — BigQuery rejects implicit FLOAT64->NUMERIC etc. -#}
        cast(_sz._n as {{ dbt.type_int() }}),
        {{ tokens_expr }},
        {{ cost_expr }},
        {#- cast to the column's type: Snowflake current_timestamp is TZ-aware but run_at is NTZ -#}
        cast({{ dbt.current_timestamp() }} as {{ dbt.type_timestamp() }})
    from (select {{ sz_select }} from {{ rel }}
        {%- if filter is not none and filter | trim != '' %}
        where {{ filter }}
        {%- endif %}) as _sz
{%- endmacro %}

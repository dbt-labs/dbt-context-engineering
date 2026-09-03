{#-
  log_ai_run: appends one row to ai_run_log per AI model run (spec §5.4). Assumes ai_run_log
  already exists; it does NOT create it. Either select ai_run_log in the same invocation (dbt's
  own DAG ordering, via the ref() below, then guarantees it builds before this hook fires), or
  wire create_ai_run_log_table() into an on-run-start hook (see that macro's docstring).

  Deliberately not a lazy self-create. Two or more AI-calling models, selected in the same
  invocation with no dependency between them, run on different threads; a lazy self-create means
  each one tries CREATE TABLE IF NOT EXISTS against the same target concurrently. Confirmed live:
  DELTA_CONCURRENT_APPEND on Databricks, a table-write rate limit on BigQuery. If ai_run_log
  genuinely does not exist when this hook fires, the INSERT below fails with the engine's own
  "table/relation does not exist" error, naming the table directly; that is intentional, not a
  gap to patch over with a friendlier wrapper.

  The inserted row carries event = 'started'. Pair with complete_ai_run(), as a post_hook using the
  SAME function_name/model_name, which appends a second row for this invocation at event =
  'completed' once the model finishes successfully. A model that errors mid-run never reaches its
  post_hook, so no 'completed' row ever appears for it; ai_run_log is append-only, so completion is
  read as "does a matching 'completed' row exist for this invocation/function_name/model_name," not
  as a mutation of the 'started' row itself. See complete_ai_run()'s own docstring for why this is
  a second INSERT rather than an UPDATE.

  Which hook phase to use depends on what `relation`/`filter` actually reference, not on
  preference, because `this` means something different before vs. after the model's own
  build/merge runs. Three cases:

  1. `relation` is an explicit ref() to some OTHER table, and `filter` (if any) doesn't reference
     `this` (e.g. sizing from a source table). Either pre_hook or post_hook works; that other
     table's state doesn't depend on THIS model's build.

  2. `relation` left at its default (`this`), sizing from the model's OWN output, no `filter`.
     Requires a POST_HOOK. Pre_hook runs before the create/merge statement, so `this` doesn't
     exist yet on a first build (errors: table does not exist) and holds last run's stale state
     on later builds either way. Only sound on a `table` (or always-fully-rebuilt) materialization,
     where "the freshly built output" and "this run's batch" are the same thing.

  3. `filter` derived from `this` (e.g. incremental_delta_predicate, which expands to
     `<unique_key> not in (select <unique_key> from {{ this }})`), the delta-scoping pattern on
     an INCREMENTAL model. Requires a PRE_HOOK. By the time a post_hook fires, this run's merge
     has already landed the new rows into `this`, so that same predicate finds nothing and logs
     row_count = 0 for a run that really processed rows.

  Never combine case 2 with an incremental model (unfiltered relation=this on an incremental); it
  is wrong in BOTH phases, not risky in just one. Pre_hook reports last run's state, missing this
  run's rows entirely. Post_hook reports the whole cumulative table, every row ever merged in, not
  this run's batch. Cases 2 and 3 can look like opposite rules for "using `this`", but they answer
  different questions (the model's total current output, vs. which rows are new this run), and
  only case 3's question has a sane answer on an incremental model.

  Usage (case 1, explicit relation, safe as either a pre_hook or post_hook):
    {{ config(post_hook = "{{ log_ai_run('classify', model_name='claude-3-5-sonnet',
                                            relation=ref('my_inputs'), input_column='text_col') }}") }}

  Usage (case 3, incremental delta, PRE_HOOK only):
    {{ config(materialized='incremental', unique_key='doc_id',
       pre_hook = [
         "{{ guard_batch(ref('stg_docs'), 'body', filter=incremental_delta_predicate('doc_id')) }}",
         "{{ log_ai_run('embed', relation=ref('stg_docs'), input_column='body',
                          filter=incremental_delta_predicate('doc_id')) }}"
       ]) }}

  Args:
    function_name  which function issued the call (generate/classify/extract/embed). Required.
    model_name     the AI model used (the largest cost lever, always logged). Optional.
    relation       relation to size the batch from. Defaults to `this` (the built model); see
                   case 2 above, only sound on a fully-rebuilt materialization, as a post_hook.
    input_column   text column for the token estimate. If omitted, est_tokens/est_cost are null.
    filter         optional SQL predicate scoping the count to the rows the run ACTUALLY processed.
                   On an incremental model the body only touches the delta, so without this the log
                   records the whole corpus every run (row_count/est_tokens/est_cost off by orders
                   of magnitude). Pass the SAME predicate the body uses; incremental_delta_predicate()
                   gives all three (body / guard_batch / here) one source of truth; see case 3
                   above. Sizing from `this` (the default) also requires that `input_column` exists
                   in the model's OUTPUT; pass relation=ref('<source>') when the source column
                   isn't carried into the output.

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
        (invocation_id, model_name, function_name, row_count, est_tokens, est_cost, run_at, event)
    select
        '{{ invocation_id }}',
        {{ model_sql }},
        '{{ function_name }}',
        {#- cast every value to the log column's type — BigQuery rejects implicit FLOAT64->NUMERIC etc. -#}
        cast(_sz._n as {{ dbt.type_int() }}),
        {{ tokens_expr }},
        {{ cost_expr }},
        {#- cast to the column's type: Snowflake current_timestamp is TZ-aware but run_at is NTZ -#}
        cast({{ dbt.current_timestamp() }} as {{ dbt.type_timestamp() }}),
        'started'
    from (select {{ sz_select }} from {{ rel }}
        {%- if filter is not none and filter | trim != '' %}
        where {{ filter }}
        {%- endif %}) as _sz
{%- endmacro %}

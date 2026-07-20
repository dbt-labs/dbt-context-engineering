{#-
  ce_cost_reconciliation — reconciles ce_ai_run_log (our heuristic estimates) against the
  engine's actual usage/billing source (spec §5.4, Phase 3). Returns a SELECT; use it as a
  model body on the warehouse:

    -- models/ce_ai_cost_reconciliation.sql
    {{ dbt_context_engineering.ce_cost_reconciliation() }}

  LIVE-VALIDATION DEFERRED: the usage sources exist only on a real warehouse (and their exact
  schemas/latency vary), so this cannot run on duckdb. Per-adapter SQL follows the parity doc and
  must be confirmed against current vendor docs at live validation. Dispatched so the right usage
  source fires per engine.
-#}

{% macro ce_cost_reconciliation() -%}
    {{ return(adapter.dispatch('ce_cost_reconciliation', 'dbt_context_engineering')()) }}
{%- endmacro %}


{% macro default__ce_cost_reconciliation() -%}
    {{ exceptions.raise_compiler_error(
        "ce_cost_reconciliation is not implemented for the '" ~ target.type ~ "' adapter. "
        ~ "Supported: snowflake, databricks, bigquery.") }}
{%- endmacro %}


{% macro snowflake__ce_cost_reconciliation() -%}
    {#- Actuals from SNOWFLAKE.ACCOUNT_USAGE (Cortex functions usage history). Joined to our log by
        day + model. Confirm the exact view/columns at live validation. -#}
    with actual as (
        select
            to_date(start_time)      as usage_date,
            model_name               as model_name,
            sum(token_credits)       as actual_credits,
            sum(tokens)              as actual_tokens
        from snowflake.account_usage.cortex_functions_usage_history
        group by 1, 2
    ),
    logged as (
        select cast(run_at as date) as usage_date, model_name,
               sum(row_count) as rows_logged, sum(est_tokens) as est_tokens, sum(est_cost) as est_cost
        from {{ ref('ce_ai_run_log') }}
        group by 1, 2
    )
    select
        l.usage_date, l.model_name, l.rows_logged, l.est_tokens, l.est_cost,
        a.actual_tokens, a.actual_credits,
        a.actual_tokens - l.est_tokens as token_delta
    from logged l
    left join actual a on l.usage_date = a.usage_date and l.model_name = a.model_name
{%- endmacro %}


{% macro databricks__ce_cost_reconciliation() -%}
    {#- Actuals from system.billing.usage (model serving line items). Confirm sku/columns live. -#}
    with actual as (
        select cast(usage_date as date) as usage_date,
               usage_metadata.endpoint_name as model_name,
               sum(usage_quantity) as actual_quantity
        from system.billing.usage
        where billing_origin_product = 'MODEL_SERVING'
        group by 1, 2
    ),
    logged as (
        select cast(run_at as date) as usage_date, model_name,
               sum(row_count) as rows_logged, sum(est_tokens) as est_tokens, sum(est_cost) as est_cost
        from {{ ref('ce_ai_run_log') }}
        group by 1, 2
    )
    select l.usage_date, l.model_name, l.rows_logged, l.est_tokens, l.est_cost, a.actual_quantity
    from logged l
    left join actual a on l.usage_date = a.usage_date and l.model_name = a.model_name
{%- endmacro %}


{% macro bigquery__ce_cost_reconciliation() -%}
    {#- Actuals from region INFORMATION_SCHEMA.JOBS (bytes/slot proxy for AI job cost). Set the
        region qualifier to match your dataset. Confirm columns at live validation. -#}
    with actual as (
        select date(creation_time) as usage_date,
               sum(total_bytes_processed) as actual_bytes
        from `region-us`.INFORMATION_SCHEMA.JOBS
        where statement_type != 'SCRIPT'
        group by 1
    ),
    logged as (
        select cast(run_at as date) as usage_date,
               sum(row_count) as rows_logged, sum(est_tokens) as est_tokens, sum(est_cost) as est_cost
        from {{ ref('ce_ai_run_log') }}
        group by 1
    )
    select l.usage_date, l.rows_logged, l.est_tokens, l.est_cost, a.actual_bytes
    from logged l
    left join actual a on l.usage_date = a.usage_date
{%- endmacro %}

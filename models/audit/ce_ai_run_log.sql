{#-
  ce_ai_run_log — append-only usage/cost log (spec §5.4, Phase 3).

  Incremental table whose own SELECT defines the schema but emits NO rows (where 1=0). Rows are
  appended by the ce_log_ai_run post-hook on each AI model run, so the log persists and grows
  across dbt invocations (a full-refresh resets it). Reconciled against engine usage sources by
  ce_cost_reconciliation.
-#}
{{ config(materialized='incremental') }}

select
    cast(null as {{ dbt.type_string() }})    as invocation_id,
    cast(null as {{ dbt.type_string() }})    as model_name,
    cast(null as {{ dbt.type_string() }})    as function_name,
    cast(null as {{ dbt.type_int() }})       as row_count,
    cast(null as {{ dbt.type_numeric() }})   as est_tokens,
    cast(null as {{ dbt.type_numeric() }})   as est_cost,
    cast(null as {{ dbt.type_timestamp() }}) as run_at
-- from (select 1) gives the WHERE a FROM (BigQuery forbids WHERE without FROM); 0 rows, typed columns
from (select 1) as _one
where 1 = 0

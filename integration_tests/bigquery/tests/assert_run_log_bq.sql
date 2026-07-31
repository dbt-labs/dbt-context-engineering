-- Validates ce_log_ai_run actually wrote a sane row on this warehouse — the post-hook INSERT and
-- its cross-engine casts (a past BigQuery FLOAT64->NUMERIC bug lived exactly here). Must run AFTER
-- the classify model that populates the log (the post-hook side effect is invisible to the DAG):
-- depends_on: {{ ref('ce_signals_bq') }}
with log as (
    select * from {{ ref('ce_ai_run_log') }}
)
select 'no_classify_row' as issue
from (select count(*) as n from log where function_name = 'classify') c where c.n < 1
union all
select 'bad_values' as issue
from log
where function_name = 'classify'
  and (row_count <> 10 or est_tokens is null or est_tokens <= 0 or run_at is null)

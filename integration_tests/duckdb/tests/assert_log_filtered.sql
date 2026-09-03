-- log_ai_run's `filter` must scope the meter to the processed rows, not the whole relation.
-- logged_filtered logs a run sized by `utterance_id > 5` (5 of 10 seed rows) under model_name
-- 'filter-test'. Its 'started' row's row_count/est_tokens must equal the FILTERED aggregates, not
-- the full-seed aggregates, and a matching 'completed' row must exist. Fail rows only — a
-- regression to whole-relation metering (row_count=10) fails here. The post-hook side effect is
-- invisible to the DAG, so depend on the logging model to run after it:
-- depends_on: {{ ref('logged_filtered') }}
with logged as (
    select row_count, est_tokens
    from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}' and model_name = 'filter-test' and event = 'started'
),
expected as (
    select
        count(*) as row_count,
        coalesce(sum({{ dbt_context_engineering.estimate_tokens('utterance_text') }}), 0) as est_tokens
    from {{ ref('fixture_utterances') }}
    where utterance_id > 5
)
select 'log_not_scoped_to_filter' as issue
from logged l, expected e
where l.row_count <> e.row_count
   or l.est_tokens <> e.est_tokens

union all

select 'missing_completed_row' as issue
from (
    select count(*) as n from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}' and model_name = 'filter-test' and event = 'completed'
) c
where c.n <> 1

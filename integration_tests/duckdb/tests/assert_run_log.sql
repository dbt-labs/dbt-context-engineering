-- ce_log_ai_run must append exactly one row for ce_logged_model's run, sized from the seed and
-- with est_cost null (no price var). Returns rows only on failure. Compares against a fresh
-- computation rather than magic numbers.
-- The post-hook side-effect is invisible to the DAG, so force this test to run AFTER the model
-- that populates the log:
-- depends_on: {{ ref('ce_logged_model') }}
with log as (
    select * from {{ ref('ce_ai_run_log') }}
),
bad_values as (
    select 'bad_values' as issue
    from log
    where function_name <> 'classify'
       or model_name <> 'test-model'
       or row_count <> (select count(*) from {{ ref('ce_fixture_utterances') }})
       or est_tokens <> (select coalesce(sum(ceil(length(utterance_text) / 4.0)), 0) from {{ ref('ce_fixture_utterances') }})
       or est_cost is not null
       or invocation_id is null
       or run_at is null
),
bad_count as (
    select 'bad_count' as issue
    from log
    having count(*) <> 1
)
select * from bad_values
union all
select * from bad_count

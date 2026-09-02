-- log_ai_run/complete_ai_run must append exactly one 'started' row and one paired 'completed' row
-- per run (see ADR-0019). ai_run_log is append-only and grows across dbt builds, so this scopes to
-- THIS invocation via invocation_id rather than a table-wide count (which fails on any second
-- build). For this run it asserts exactly one classify 'started' row, valid and sized from the
-- seed using the same estimate_tokens / price the logger uses, plus exactly one matching
-- 'completed' row. Rows only on failure; expected values are computed, not magic numbers. The
-- post-hook side effect is invisible to the DAG, so depend on the logging model to run after it:
-- depends_on: {{ ref('logged_model') }}
{% set price = var('cost_per_1k_tokens', none) %}
with log as (
    select * from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}' and function_name = 'classify'
),
started as (
    select * from log where event = 'started'
),
expected as (
    select
        (select count(*) from {{ ref('fixture_utterances') }}) as exp_row_count,
        (select coalesce(sum({{ dbt_context_engineering.estimate_tokens('utterance_text') }}), 0)
         from {{ ref('fixture_utterances') }}) as exp_est_tokens
),
bad_count as (
    select 'bad_count' as issue
    from (select count(*) as n from log) c
    where c.n <> 2
),
bad_started_values as (
    select 'bad_started_values' as issue
    from started cross join expected
    where started.model_name is null
       or started.row_count <> expected.exp_row_count
       or started.est_tokens <> expected.exp_est_tokens
       or started.run_at is null
       {% if price is none %}or started.est_cost is not null{% else %}or started.est_cost <> cast(expected.exp_est_tokens / 1000.0 * {{ price }} as {{ dbt.type_numeric() }}){% endif %}
),
missing_completed_row as (
    select 'missing_completed_row' as issue
    from (select count(*) as n from log where event = 'completed') c
    where c.n <> 1
)
select * from bad_count
union all select * from bad_started_values
union all select * from missing_completed_row

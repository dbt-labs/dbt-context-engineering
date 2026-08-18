-- log_ai_run must append exactly one correct row per run (see ADR-0019). ai_run_log is
-- append-only and grows across dbt builds, so this scopes to THIS invocation via invocation_id
-- rather than a table-wide count (which fails on any second build). For this run it asserts exactly
-- one classify row, valid and sized from the seed using the same estimate_tokens / price the
-- logger uses. Rows only on failure; expected values are computed, not magic numbers. The post-hook
-- side effect is invisible to the DAG, so depend on the logging model to run after it:
-- depends_on: {{ ref('signals') }}
{% set price = var('cost_per_1k_tokens', none) %}
with log as (
    select * from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}' and function_name = 'classify'
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
    where c.n <> 1
),
bad_values as (
    select 'bad_values' as issue
    from log cross join expected
    where log.model_name is null
       or log.row_count <> expected.exp_row_count
       or log.est_tokens <> expected.exp_est_tokens
       or log.run_at is null
       or log.completed <> true
       {% if price is none %}or log.est_cost is not null{% else %}or log.est_cost <> cast(expected.exp_est_tokens / 1000.0 * {{ price }} as {{ dbt.type_numeric() }}){% endif %}
)
select * from bad_count
union all select * from bad_values

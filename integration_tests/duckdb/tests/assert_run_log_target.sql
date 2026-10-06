-- Hook writes are invisible to the DAG; this test shares the build invocation with logged_model.
-- Zero rows means both lifecycle records landed in the current target's run log.
-- depends_on: {{ ref('logged_model') }}
-- depends_on: {{ ref('ai_run_log') }}
{% if var('ai_functions_enabled', false) %}
with expected_events as (
    select 'started' as event
    union all
    select 'completed' as event
),
current_rows as (
    select event, node_id
    from {{ dbt_context_engineering.ai_run_log_relation() or ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and model_name = 'test-model'
      and function_name = 'classify'
),
missing_events as (
    select expected_events.event, 'missing_event' as issue
    from expected_events
    left join current_rows using (event)
    where current_rows.event is null
),
invalid_rows as (
    select event, 'wrong_node_id' as issue
    from current_rows
    where node_id is distinct from 'model.duckdb_tests.logged_model'
)
select * from missing_events
union all
select * from invalid_rows
{% else %}
select cast(null as {{ dbt.type_string() }}) as issue
where 1 = 0
{% endif %}

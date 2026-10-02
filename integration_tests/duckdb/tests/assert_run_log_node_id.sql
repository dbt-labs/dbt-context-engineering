-- Hook side effects are invisible to the DAG, so this test runs after logged_model.
-- Return unexpected or missing lifecycle rows; zero rows means both events have the expected node_id.
-- depends_on: {{ ref('logged_model') }}
with expected_events as (
    select 'started' as event
    union all
    select 'completed' as event
),
current_rows as (
    select event, node_id
    from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and model_name = 'test-model'
      and function_name = 'classify'
),
bad_rows as (
    select event, node_id, 'wrong_node_id' as issue
    from current_rows
    where node_id is distinct from 'model.duckdb_tests.logged_model'
),
missing_events as (
    select expected_events.event, cast(null as {{ dbt.type_string() }}) as node_id,
           'missing_event' as issue
    from expected_events
    left join current_rows using (event)
    where current_rows.event is null
)
select * from bad_rows
union all
select * from missing_events

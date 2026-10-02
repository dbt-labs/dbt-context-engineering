-- Hook side effects are invisible to the DAG, so this test runs after signals.
-- Return unexpected or missing lifecycle rows; zero rows means both events carry the signals
-- model's unique_id. Scoped to THIS invocation because ai_run_log grows across builds.
-- depends_on: {{ ref('signals') }}
{% set expected_node_id = 'model.' ~ project_name ~ '.signals' %}
with expected_events as (
    select 'started' as event
    union all
    select 'completed' as event
),
current_rows as (
    select event, node_id
    from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and function_name = 'classify'
),
bad_rows as (
    select event, node_id, 'wrong_node_id' as issue
    from current_rows
    where node_id is null or node_id <> '{{ expected_node_id }}'
),
missing_events as (
    select expected_events.event, cast(null as {{ dbt.type_string() }}) as node_id,
           'missing_event' as issue
    from expected_events
    left join current_rows on expected_events.event = current_rows.event
    where current_rows.event is null
)
select * from bad_rows
union all
select * from missing_events

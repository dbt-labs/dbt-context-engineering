{{ config(
    enabled = var('gate_probe', none) == 'decide_unsupported',
    materialized = 'table'
) }}

{#- Negative-test probe: decide() on an engine without a decision model must stop at compile time
    and name classify() as the route. duckdb is such an engine. CI asserts on the message. -#}
select 1 as id, {{ dbt_context_engineering.decide("'probe text'", {
    'topic': {'type': 'choice', 'instructions': 'Which topic?', 'criteria': {'a': 'first', 'b': 'second'}}
}) }} as d

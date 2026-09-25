{{ config(
    enabled = var('gate_probe', none) == 'ai_functions_enabled',
    materialized = 'table'
) }}

{#- Negative-test probe for require_ai_functions_enabled. Disabled unless selected with
    --vars '{gate_probe: ai_functions_enabled}', so a normal `dbt build` never sees it.

    embed() has no duckdb implementation, so this model can never succeed here. That is fine and
    is the point: the gates run in embed()'s outer macro BEFORE adapter.dispatch, so which error
    comes back says which gate fired. CI asserts on the MESSAGE, not just a non-zero exit, because
    an exit code alone cannot tell "the spend gate stopped us" apart from "duckdb has no embed".
    The positive control runs the same model with ai_functions_enabled: true and requires the
    "not implemented for the 'duckdb' adapter" message instead, which is only reachable if the
    gate stayed quiet. -#}
select 1 as id, {{ dbt_context_engineering.embed("'probe text'") }} as v

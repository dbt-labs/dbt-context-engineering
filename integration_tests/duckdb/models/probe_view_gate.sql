{{ config(
    enabled = var('gate_probe', none) == 'safe_materialization',
    materialized = 'view'
) }}

{#- Negative-test probe for require_safe_materialization. Disabled unless selected with
    --vars '{gate_probe: safe_materialization}'. A view wrapping an AI call recomputes that call
    on every query against the model, so the gate must raise before dispatch. Run with
    ai_functions_enabled: true so the spend gate is already satisfied and this is the next gate
    in line. See probe_ai_gate.sql for why CI asserts on the message text. -#}
select 1 as id, {{ dbt_context_engineering.embed("'probe text'") }} as v

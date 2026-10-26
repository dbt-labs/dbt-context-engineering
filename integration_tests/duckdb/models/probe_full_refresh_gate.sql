{{ config(
    enabled = var('gate_probe', none) == 'full_refresh_gate',
    materialized = 'incremental'
) }}

{#- Negative-test probe for require_full_refresh_gate. Disabled unless selected with
    --vars '{gate_probe: full_refresh_gate}'. Deliberately sets NO full_refresh config, which is
    the condition the gate exists to catch: an AI-calling incremental model left exposed to any
    bare --full-refresh. Run with ai_functions_enabled: true so the two earlier gates are already
    satisfied. See probe_ai_gate.sql for why CI asserts on the message text. -#}
select 1 as id, {{ dbt_context_engineering.embed("'probe text'") }} as v

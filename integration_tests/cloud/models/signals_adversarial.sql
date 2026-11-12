{{ config(materialized='table') }}
{#- LIVE escaping test (#5 backslash prompt, #6 apostrophe enum label, #2 tolerant {{input}} match).
    classify emits an escaped prompt literal + an escaped enum array (vendor array literal per
    engine); if any escaping regresses the SQL is invalid and THIS BUILD FAILS on the warehouse —
    the failure is the signal. Runs in the normal baseline (with ai_functions_enabled: true);
    passed in the 2026-11-10 baselines (TESTING.md §3.3; PR #32). -#}
select
    utterance_id,
    {{ dbt_context_engineering.classify(
        'utterance_text',
        dbt_context_engineering.prompt('adv_escape', 'v1'),
        dbt_context_engineering.schema_def('adv_escape', 'v1')
    ) }} as signal
from {{ ref('fixture_utterances') }}

{{ config(
    materialized='table',
    meta={'ai_prompt': {'name': 'EXAMPLE_signal_classify', 'version': 'v3'}},
    pre_hook="{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text', output_tokens=50) }}"
) }}

{#- guard_pass's twin, sized with the meta.ai_prompt prompt and schema plus an output allowance
    per row. Passes under default ceilings. CI rebuilds guard_pass and this model under one
    max_est_tokens that the input text alone fits under and the full per-row estimate does not, so
    guard_pass must pass and this model must trip (ADR-0035). -#}
select count(*) as guarded_rows from {{ ref('fixture_utterances') }}

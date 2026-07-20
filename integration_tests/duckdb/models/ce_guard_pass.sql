{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.ce_guard_batch(ref('ce_fixture_utterances'), 'utterance_text') }}"
) }}

{#- The guard runs as a pre-hook against the 10-row seed. Under default ceilings
    (ce_max_batch_rows=10000) it passes, proving the guard allows normal batches. The RAISE path
    is exercised separately by rebuilding with --vars '{ce_max_batch_rows: 3}' (see CI / phase notes). -#}
select count(*) as guarded_rows from {{ ref('ce_fixture_utterances') }}

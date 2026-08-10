{{ config(
    materialized = 'incremental',
    unique_key   = 'utterance_id',
    pre_hook     = [
        "{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text',
             filter=logged_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name='logged-delta-test',
             relation=ref('fixture_utterances'), input_column='utterance_text',
             filter=logged_delta_filter()) }}"
    ]
) }}

{#- Closes the gap logged_filtered's own comment dodges ("Uses an explicit predicate rather than
    the incremental helper so the assertion is exact and needs no cross-run sequencing"). This is
    the real, dynamic case: guard_batch and log_ai_run both wired as PRE-hooks (the fixed README
    pattern), both scoped by the SAME logged_delta_filter() the body uses, exercised across two
    sequential builds against the 10-row fixture_utterances seed.

    Phase 1 (ld_phase=1, the default): processes utterance_id <= 5 only, a 5-row baseline.
    Phase 2 (ld_phase=2, run WITHOUT --full-refresh right after phase 1): processes the full
    10-row fixture; utterance_id 6-10 is the real incremental delta (5 rows). log_ai_run's row
    from phase 2 must show row_count=5, proving a pre-hook log_ai_run measures the same pre-merge
    delta the model body and guard_batch use.

    A post-hook log_ai_run using the same filter would show row_count=0 here instead: by the time
    a post-hook fires, this run's merge has already landed utterance_id 6-10 into `this`, so the
    same "not in this" predicate finds nothing post-merge. See dbt_gong's ADR-0006
    (github.com/fivetran/dbt_gong) for the live reproduction that surfaced this. -#}
select utterance_id, utterance_text
from {{ ref('fixture_utterances') }}
where {{ logged_delta_filter() }}

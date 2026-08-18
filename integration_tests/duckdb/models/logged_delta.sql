{{ config(
    materialized = 'incremental',
    unique_key   = 'utterance_id',
    pre_hook     = [
        "{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text',
             filter=logged_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run('embed', model_name='logged-delta-test',
             relation=ref('fixture_utterances'), input_column='utterance_text',
             filter=logged_delta_filter()) }}"
    ],
    post_hook    = "{{ dbt_context_engineering.complete_ai_run('embed', model_name='logged-delta-test') }}"
) }}

{#- Exercises guard_batch and log_ai_run as PRE-hooks against a genuine incremental delta, both
    scoped by the SAME logged_delta_filter() the body uses below, across two sequential builds of
    the 10-row fixture_utterances seed. guard_batch, the log, and the model body all need to agree
    on exactly which rows a given run touches, or the guard's ceiling check and the log's row_count
    describe a different batch than the one actually processed.

    Pre-hook placement is required here specifically because logged_delta_filter() derives from
    `this` (via incremental_delta_predicate's "not already in the target table" check). That check
    reads the target table's state at the moment it runs. A pre-hook runs before this run's merge,
    so it still sees yesterday's rows and correctly finds today's new ones; a hook running after
    the merge would find the target already holding the very rows it's looking for, and report
    zero. Running guard_batch and log_ai_run in the same phase, before the merge, keeps both
    reading the same state the model body's own `where` clause reads.

    Phase 1 (ld_phase=1, the default): processes utterance_id <= 5 only, a 5-row baseline.
    Phase 2 (ld_phase=2, run WITHOUT --full-refresh right after phase 1): processes the full
    10-row fixture; utterance_id 6-10 is the real incremental delta (5 rows). log_ai_run's row
    from phase 2 records row_count=5, the actual number of rows this run processed.

    complete_ai_run runs as a post_hook (safe here even though log_ai_run is a pre_hook — its
    UPDATE is keyed on invocation_id/function_name/model_name, never on `this`) and flips that same
    row to completed=true once the model body finishes.
 -#}
select utterance_id, utterance_text
from {{ ref('fixture_utterances') }}
where {{ logged_delta_filter() }}

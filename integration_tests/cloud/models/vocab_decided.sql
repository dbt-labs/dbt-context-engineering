{{ config(
    materialized = 'incremental',
    unique_key   = 'utterance_id',
    full_refresh = var('vocab_full_refresh', true),
    meta         = {'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}},
    pre_hook     = [
        "{{ dbt_context_engineering.guard_batch(ref('vocab_stg'), 'utterance_text', filter=vocab_delta_filter()) }}",
        "{{ dbt_context_engineering.log_ai_run(dbt_context_engineering.vocabulary_method(), model_name='vocab-pipeline-test',
             relation=ref('vocab_stg'), input_column='utterance_text', filter=vocab_delta_filter()) }}"
    ],
    post_hook    = "{{ dbt_context_engineering.complete_ai_run(dbt_context_engineering.vocabulary_method(), model_name='vocab-pipeline-test') }}"
) }}

{#- LIVE fixed-vocabulary pipeline, step 1: one AI call per row in the batch. The vocabulary is named
    once, in meta.ai_vocabulary; the body, the delta filter and both hooks read it, and the hooks
    size each row's call from it with no prompt arguments (ADR-0035, ADR-0037). decide() on
    Databricks; on Snowflake and BigQuery this project sets decide_fallback: classify, so the same
    model labels with classify() from the same vocabulary. Reviewed rows are never sent
    (vocab_delta_filter). full_refresh is opted in here so this test project rebuilds cleanly under
    --full-refresh; a real project should leave it off so a shared --full-refresh cannot re-trigger
    the spend. -#}
-- depends_on: {{ ref('vocab_reviews') }}
{{ dbt_context_engineering.vocabulary_decide(ref('vocab_stg'), 'utterance_id', 'utterance_text',
    filter=vocab_delta_filter()) }}

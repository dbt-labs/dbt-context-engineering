{{ config(
    enabled = var('gate_probe', none) == 'vocabulary_fallback',
    materialized = 'incremental',
    unique_key = 'utterance_id',
    full_refresh = false,
    meta = {'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}
) }}

{#- Negative-test probe: on an engine without a decision model, vocabulary_decide must stop with
    the decide_fallback message by default. duckdb is such an engine. CI asserts on the message. -#}
{{ dbt_context_engineering.vocabulary_decide(ref('vocab_delta_stg'), 'utterance_id', 'utterance_text') }}

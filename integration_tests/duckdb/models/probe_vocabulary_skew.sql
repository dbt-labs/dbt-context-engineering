{{ config(
    enabled = var('gate_probe', none) == 'vocabulary_skew',
    materialized = 'table',
    meta = {'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}
) }}

{#- Negative-test probe for vocabulary_require_in_sync: this labels model reads call_topics v1, but
    vocab_decided_skewed holds rows decided with v0. The build must stop before writing, naming
    both keys. CI asserts on the message. -#}
{{ dbt_context_engineering.vocabulary_labels(ref('vocab_decided_skewed'), 'utterance_id', threshold=0.7, method='decide') }}

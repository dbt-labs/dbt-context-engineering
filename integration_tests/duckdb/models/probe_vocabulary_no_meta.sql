{{ config(enabled = var('gate_probe', none) == 'vocabulary_no_meta', materialized = 'table') }}

{#- Negative-test probe: a vocabulary macro on a model with no meta.ai_vocabulary and no name= /
    version= must stop at compile time and say how to name one. CI asserts on the message. -#}
{{ dbt_context_engineering.vocabulary_labels(ref('vocab_decided_seeded'), 'utterance_id', threshold=0.7, method='decide') }}

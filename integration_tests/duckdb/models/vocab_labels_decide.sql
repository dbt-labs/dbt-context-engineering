{{ config(materialized='table', meta={'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}) }}
{#- The vocabulary is named once, in meta.ai_vocabulary. -#}
{{ dbt_context_engineering.vocabulary_labels(ref('vocab_decided_seeded'), 'utterance_id',
    threshold=0.7, review_relation=ref('vocab_reviews'), method='decide') }}

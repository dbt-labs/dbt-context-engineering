{{ config(materialized='table', meta={'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}) }}
{{ dbt_context_engineering.vocabulary_labels(ref('vocab_decided_classify_seeded'), 'utterance_id', method='classify') }}

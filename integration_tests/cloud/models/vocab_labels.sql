{{ config(materialized='table', meta={'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}) }}
{#- LIVE fixed-vocabulary pipeline, step 2: no AI call. Routes by confidence at 0.6 on the decide
    path and joins the review fixture, whose approved term wins. -#}
{{ dbt_context_engineering.vocabulary_labels(ref('vocab_decided'), 'utterance_id',
    threshold=0.6, review_relation=ref('vocab_reviews')) }}

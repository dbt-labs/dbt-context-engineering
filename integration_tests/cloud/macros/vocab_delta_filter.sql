{#- Shared by vocab_decided's body and both hooks, the content_hash_delta_filter pattern: hook
    strings render as their own templates, so only a macro is visible to all three. The vocabulary
    comes from the calling model's meta.ai_vocabulary. -#}
{% macro vocab_delta_filter() %}
    {{ return(dbt_context_engineering.vocabulary_delta_predicate('utterance_id', review_relation=ref('vocab_reviews'))) }}
{% endmacro %}

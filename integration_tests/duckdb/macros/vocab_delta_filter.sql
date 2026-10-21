{#- Shared by vocab_delta_standin's body and any hook, the content_hash_delta_filter pattern. The
    vocabulary comes from the calling model's meta.ai_vocabulary. -#}
{% macro vocab_delta_filter() %}
    {{ return(dbt_context_engineering.vocabulary_delta_predicate(
        'utterance_id', review_relation=ref('vocab_reviews'), method='decide')) }}
{% endmacro %}

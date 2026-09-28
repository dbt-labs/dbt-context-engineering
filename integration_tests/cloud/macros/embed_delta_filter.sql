{#- Shared by embed_delta.sql's body, its guard_batch pre-hook, and its log_ai_run pre-hook, so
    all three agree on exactly which rows this run touches. pre_hook and post_hook strings are
    re-rendered as their own independent Jinja template at hook execution time, so a body-local
    {% set %} is not visible to them and only a macro is. Same reason content_hash_delta_filter
    exists. -#}
{% macro embed_delta_filter() %}
    {%- set fingerprint = dbt_context_engineering.embedding_fn_fingerprint() -%}
    {%- set delta = dbt_context_engineering.incremental_delta_predicate(
        'utterance_id', fingerprint, 'embedding_fn_fingerprint', content_hash_column='content_hash'
    ) -%}
    {{ return(delta) }}
{% endmacro %}

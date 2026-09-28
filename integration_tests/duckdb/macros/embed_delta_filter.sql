{#- Shared by embed_delta.sql's body, its guard_batch pre-hook, and its log_ai_run pre-hook, so
    all three agree on exactly which rows this run touches. pre_hook and post_hook strings are
    re-rendered as their own independent Jinja template at hook execution time, so a body-local
    {% set %} is not visible to them and only a macro is. Same reason content_hash_delta_filter
    exists. -#}
{% macro embed_delta_filter() %}
    {#- Same stand-in model name embed_delta.sql uses. The fingerprint here and in the model
        body must agree, or the delta predicate sees a fingerprint change on every run and
        reprocesses the whole corpus. duckdb sets no embedding_model var, so the default
        form would raise here anyway. -#}
    {%- set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model='embed-delta-standin') -%}
    {%- set delta = dbt_context_engineering.incremental_delta_predicate(
        'utterance_id', fingerprint, 'embedding_fn_fingerprint', content_hash_column='content_hash'
    ) -%}
    {{ return(delta) }}
{% endmacro %}

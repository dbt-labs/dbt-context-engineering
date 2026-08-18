{#- Shared by content_hash_delta.sql's body, guard_batch pre-hook, and log_ai_run pre-hook, so all
    three agree on exactly which rows this run touches, the same reason logged_delta_filter()
    exists: pre_hook/post_hook strings are re-rendered as their own independent Jinja template at
    hook execution time, so a body-local {% set %} isn't visible to them, only a macro is.

    embedding_fn_fingerprint() is a pure function of its args (no `this`/is_incremental()
    dependency), so calling it again here alongside the model body's own call is safe, the two
    calls are guaranteed to agree, the same characteristic incremental_delta_predicate() has when
    called independently 2-3 times per build. -#}
{% macro content_hash_delta_filter() %}
    {%- set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model='content-hash-delta-test') -%}
    {%- set delta = dbt_context_engineering.incremental_delta_predicate(
        'utterance_id', fingerprint, 'embedding_fn_fingerprint', content_hash_column='content_hash'
    ) -%}
    {{ return(delta) }}
{% endmacro %}

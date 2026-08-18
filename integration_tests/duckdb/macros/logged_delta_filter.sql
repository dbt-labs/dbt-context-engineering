{#- Shared by logged_delta.sql's body, guard_batch pre-hook, and log_ai_run pre-hook, so all three
    agree on exactly which rows this run touches. A local {% set %} in the model body can't be used
    here: pre_hook/post_hook strings are re-rendered as their own independent Jinja template at hook
    execution time, so they only see globally-visible vars/macros, not the body's local variables.
    This macro recomputes both the phase limit and the real incremental delta fresh on every call,
    which is safe since both are idempotent (var() lookup, and a live is_incremental()/this query),
    matching how incremental_delta_predicate itself is already called independently 2-3 times. -#}
{% macro logged_delta_filter() %}
    {%- set limit = 5 if var('ld_phase', 1) == 1 else 10 -%}
    {%- set delta = dbt_context_engineering.incremental_delta_predicate('utterance_id') -%}
    {{ return('utterance_id <= ' ~ limit ~ (' and ' ~ delta if delta else '')) }}
{% endmacro %}

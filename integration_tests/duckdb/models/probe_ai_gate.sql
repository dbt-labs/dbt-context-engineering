{{ config(
    enabled = var('gate_probe', none) == 'ai_functions_enabled',
    materialized = 'table'
) }}

{#- Negative-test probe for require_ai_functions_enabled, and (with ai_functions_enabled: true)
    the positive control proving the gate itself stayed quiet rather than the build succeeding
    for an unrelated reason. Disabled unless selected with --vars '{gate_probe:
    ai_functions_enabled}', so a normal `dbt build` never sees it.

    ai_wrapper selects which of the five AI wrappers to probe, default 'embed' (the original,
    still what every non-wrapper-specific CI step in this file's history exercises). None of the
    five has a duckdb implementation, so this model can never succeed here regardless of which one
    is selected. That is fine and is the point: the gates run in each wrapper's outer macro BEFORE
    adapter.dispatch, so which error comes back says which gate fired. CI asserts on the MESSAGE,
    not just a non-zero exit, because an exit code alone cannot tell "the spend gate stopped us"
    apart from "duckdb has no <wrapper>". The positive control runs the same model with
    ai_functions_enabled: true and requires the "not implemented for the 'duckdb' adapter" message
    instead, which is only reachable if the gate stayed quiet.

    classify and extract require output_schema, and generate requires prompt. None of the four
    default__ implementations touch either argument before raising (confirmed by reading
    default__classify/extract/generate/ai_agg: each raises unconditionally, before output_schema
    or prompt is ever used), so the literal placeholders below only need to be non-none, not valid
    schema/prompt text. -#}

{% set wrapper = var('ai_wrapper', 'embed') %}

{% if wrapper == 'embed' -%}
select 1 as id, {{ dbt_context_engineering.embed("'probe text'") }} as v
{%- elif wrapper == 'classify' -%}
select 1 as id, {{ dbt_context_engineering.classify("'probe text'", "'probe prompt'", '{"placeholder": true}') }} as v
{%- elif wrapper == 'extract' -%}
select 1 as id, {{ dbt_context_engineering.extract("'probe text'", "'probe prompt'", '{"placeholder": true}') }} as v
{%- elif wrapper == 'generate' -%}
select 1 as id, {{ dbt_context_engineering.generate("'probe text'", "'probe prompt'") }} as v
{%- elif wrapper == 'ai_agg' -%}
select 1 as id, {{ dbt_context_engineering.ai_agg("'probe text'", "'probe prompt'") }} as v
{%- else -%}
    {{ exceptions.raise_compiler_error("probe_ai_gate: unknown ai_wrapper '" ~ wrapper ~ "'. Expected embed, classify, extract, generate, or ai_agg.") }}
{%- endif %}

{{ config(enabled = var('gate_probe', none) == 'vocabulary_invalid', materialized = 'table') }}

{#- Negative-test probe for validate_vocabulary. --vars '{vocab_case: <name>}' picks a malformed
    vocabulary; CI asserts on each message. -#}
{%- set ok = {'label': 'a', 'definition': 'x'} -%}
{%- set cases = {
    'no_instructions': {'terms': [ok]},
    'bad_label':       {'instructions': 'x', 'terms': [{'label': 'Bad Label', 'definition': 'x'}]},
    'duplicate':       {'instructions': 'x', 'terms': [ok, ok]},
    'no_definition':   {'instructions': 'x', 'terms': [{'label': 'a'}]},
    'bad_status':      {'instructions': 'x', 'terms': [{'label': 'a', 'definition': 'x', 'status': 'retired'}]},
    'none_active':     {'instructions': 'x', 'terms': [{'label': 'a', 'definition': 'x', 'status': 'deprecated'}]},
} -%}
{%- do dbt_context_engineering.validate_vocabulary(cases[var('vocab_case', 'no_instructions')], 'probe') -%}
select 1 as id

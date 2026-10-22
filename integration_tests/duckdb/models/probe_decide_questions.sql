{{ config(
    enabled = var('gate_probe', none) == 'decide_questions',
    materialized = 'table'
) }}

{#- Negative-test probe for validate_decide_questions. --vars '{decide_case: <name>}' picks one
    malformed question set; CI asserts on each message. The cap is passed explicitly (2) because
    duckdb has no engine cap. -#}
{%- set cases = {
    'bad_type':     {'q': {'type': 'pick', 'instructions': 'x'}},
    'no_criteria':  {'q': {'type': 'choice', 'instructions': 'x'}},
    'over_cap':     {'q': {'type': 'choice', 'instructions': 'x', 'criteria': {'a': '1', 'b': '2', 'c': '3'}}},
    'score_levels': {'q': {'type': 'score', 'instructions': 'x', 'criteria': ['only_one']}},
    'bad_id':       {'1q': {'type': 'noul', 'instructions': 'x'}},
    'extra_field':  {'q': {'type': 'noul', 'instructions': 'x', 'options': {}}},
    'noul_keys':    {'q': {'type': 'noul', 'instructions': 'x', 'criteria': {'maybe': 'y'}}},
    'score_repeat': {'q': {'type': 'score', 'instructions': 'x', 'criteria': ['low', 'low']}},
    'choice_blank': {'q': {'type': 'choice', 'instructions': 'x', 'criteria': {'a': ' '}}},
    'noul_blank':   {'q': {'type': 'noul', 'instructions': 'x', 'criteria': {'true': ''}}},
} -%}
{%- do dbt_context_engineering.validate_decide_questions(cases[var('decide_case', 'bad_type')], 2) -%}
select 1 as id

{{ config(
    enabled = var('gate_probe', none) == 'decide_questions',
    materialized = 'table'
) }}

{#- Negative-test probe for validate_decide_questions. --vars '{decide_case: <name>}' picks one
    malformed question set; CI asserts on each message. The limits are passed explicitly, small
    enough to trip with tiny question sets, because duckdb has no engine limits. -#}
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
    'under_min':    {'q': {'type': 'choice', 'instructions': 'x', 'criteria': {'a': '1'}}},
    'too_many_q':   {'q1': {'type': 'noul', 'instructions': 'x'}, 'q2': {'type': 'noul', 'instructions': 'x'},
                     'q3': {'type': 'noul', 'instructions': 'x'}, 'q4': {'type': 'noul', 'instructions': 'x'}},
    'id_too_long':  {'abcdefghi': {'type': 'noul', 'instructions': 'x'}},
    'over_options': {'q1': {'type': 'choice', 'instructions': 'x', 'criteria': {'a': '1', 'b': '2'}},
                     'q2': {'type': 'score', 'instructions': 'x', 'criteria': ['l1', 'l2', 'l3', 'l4']}},
} -%}
{%- set limits = {'choice_min': 2, 'choice_max': 2, 'max_questions': 3, 'max_options': 5, 'max_id_length': 8} -%}
{%- do dbt_context_engineering.validate_decide_questions(cases[var('decide_case', 'bad_type')], limits) -%}
select 1 as id

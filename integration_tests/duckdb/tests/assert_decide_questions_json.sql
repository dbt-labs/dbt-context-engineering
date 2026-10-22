-- decide_questions_json keeps declared order (question ids, each question's fields, choice labels)
-- and escapes like tojson, so dbt Core and Fusion send the same ai_decide request. Fusion's tojson
-- sorts dict keys and Core's does not, so this test runs on both engines with the exact expected
-- text. Checked at compile time; a failed check renders a row.
{%- set questions = {
    'topic': {'type': 'choice', 'instructions': 'Which "topic"?', 'criteria': {'zebra': 'Z desc', 'apple': 'A desc'}},
    'alpha': {'type': 'noul', 'instructions': 'Is it?', 'criteria': {'true': 'yes', 'false': 'no'}},
    'tone':  {'type': 'score', 'instructions': 'How?', 'criteria': ['low', 'high']}
} -%}
{%- set expected -%}
{"topic": {"type": "choice", "instructions": "Which \"topic\"?", "criteria": {"zebra": "Z desc", "apple": "A desc"}}, "alpha": {"type": "noul", "instructions": "Is it?", "criteria": {"true": "yes", "false": "no"}}, "tone": {"type": "score", "instructions": "How?", "criteria": ["low", "high"]}}
{%- endset -%}
{%- set got = dbt_context_engineering.decide_questions_json(questions) -%}
{%- set checks = {
    'exact_text':   got == expected,
    'same_length_as_tojson': (got | length) == (tojson(questions) | length),
    'parses_back':  fromjson(got) == questions
} %}
select 'ok' as check_name where 1 = 0
{%- for name, passed in checks.items() %}
{%- if not passed %}
union all select '{{ name }}'
{%- endif %}
{%- endfor %}

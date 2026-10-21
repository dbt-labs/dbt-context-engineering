{#- The decide() question set for the live battery: one question of each type, over the
    fixture_utterances sales-call transcript. Called by the model body and both hooks, so the
    questions are defined once. -#}
{% macro decide_test_questions() -%}
    {{ return({
        'topic': {
            'type': 'choice',
            'instructions': 'What is this sales-call utterance mainly about?',
            'criteria': {
                'pipeline_reliability': 'Data pipelines or loads failing, breaking or running late',
                'observability': 'Seeing what failed and why: monitoring, alerting, lineage',
                'pricing': 'Cost, price, budget or contract terms',
                'other': 'Greetings, small talk, or anything not covered above'
            }
        },
        'frustrated': {
            'type': 'noul',
            'instructions': 'The speaker sounds frustrated'
        },
        'tone': {
            'type': 'score',
            'instructions': 'How negative is the speaker tone?',
            'criteria': ['calm', 'concerned', 'upset']
        }
    }) }}
{%- endmacro %}

{#- Test vocabulary for the fixed-vocabulary pipeline: four active terms over the fixture
    sales-call transcript, plus one deprecated term that must never be offered to the model. -#}
{% macro vocabulary__call_topics__v1() -%}
    {{ return({
        'instructions': 'What is this sales-call utterance mainly about?',
        'terms': [
            {'label': 'pipeline_reliability',
             'definition': 'Data pipelines or loads failing, breaking or running late.',
             'scope_note': 'Not about seeing what failed; that is observability.',
             'synonyms': ['broken load', 'failed nightly run'],
             'valid_from': '2026-10-01'},
            {'label': 'observability',
             'definition': 'Seeing what failed and why: monitoring, alerting, lineage.'},
            {'label': 'pricing',
             'definition': 'Cost, price, budget or contract terms.'},
            {'label': 'other',
             'definition': 'Greetings, small talk, or anything not covered by another term.'},
            {'label': 'legacy_tooling',
             'definition': 'Complaints about a tool the customer has already replaced.',
             'status': 'deprecated',
             'valid_from': '2026-01-01', 'valid_to': '2026-09-30'}
        ]
    }) }}
{%- endmacro %}

-- The one vocabulary renders both paths without drifting: the decide() choice question offers
-- exactly the active terms, with scope notes and synonyms folded into the description; the
-- classify() schema's enum is the same label set; the classify() prompt names every active term
-- and keeps the {{ '{{' }} input {{ '}}' }} placeholder. Deprecated terms appear in neither. Checked at compile time;
-- a failed check renders a row.
{%- set q = dbt_context_engineering.vocabulary_question('call_topics', 'v1') -%}
{%- set crit = q['term']['criteria'] -%}
{%- set enum = fromjson(dbt_context_engineering.vocabulary_schema('call_topics', 'v1'))['properties']['term']['enum'] -%}
{%- set prompt = dbt_context_engineering.vocabulary_prompt('call_topics', 'v1') -%}
{%- set active = ['pipeline_reliability', 'observability', 'pricing', 'other'] -%}
{%- set checks = {
    'question_type':      q['term']['type'] == 'choice',
    'question_labels':    (crit.keys() | list) == active,
    'question_scope':     'Scope: Not about seeing what failed' in crit['pipeline_reliability'],
    'question_synonyms':  'Also called: broken load, failed nightly run' in crit['pipeline_reliability'],
    'schema_enum':        enum == active,
    'prompt_terms':       ('- pricing: Cost, price, budget or contract terms.' in prompt) and ('legacy_tooling' not in prompt),
    'prompt_placeholder': prompt.endswith('Text: {{ input }}'),
    'key':                dbt_context_engineering.vocabulary_key('call_topics', 'v1', 'decide') == 'call_topics@v1/decide'
} %}
select 'ok' as check_name where 1 = 0
{%- for name, passed in checks.items() %}
{%- if not passed %}
union all select '{{ name }}'
{%- endif %}
{%- endfor %}

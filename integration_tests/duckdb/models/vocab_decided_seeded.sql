{{ config(materialized='table') }}

{#- Stand-in for vocabulary_decide's output on the decide path: decision results in the Databricks
    ai_decide envelope, seeded so vocabulary_labels' routing, runner-up ranking and review join are
    tested deterministically. No AI call. Threshold under test is 0.7.
      1 accepted (0.92), runner-up observability
      2 needs_review (0.55, below threshold)
      3 needs_review (engine error)
      4 needs_review (deprecated term returned, not an active label)
      5 accepted by the model, overridden by the latest of two reviews
      6 accepted at exactly the threshold -#}
{%- set cases = [
    (1, {'type': 'choice', 'choice': 'pipeline_reliability', 'confidence': 0.92, 'probabilities': {'pipeline_reliability': 0.9, 'observability': 0.07, 'pricing': 0.02, 'other': 0.01}}, none),
    (2, {'type': 'choice', 'choice': 'observability', 'confidence': 0.55, 'probabilities': {'pipeline_reliability': 0.35, 'observability': 0.6, 'pricing': 0.0, 'other': 0.05}}, none),
    (3, none, 'state too long'),
    (4, {'type': 'choice', 'choice': 'legacy_tooling', 'confidence': 0.95, 'probabilities': {'pipeline_reliability': 0.05, 'observability': 0.0, 'pricing': 0.0, 'other': 0.0}}, none),
    (5, {'type': 'choice', 'choice': 'pricing', 'confidence': 0.8, 'probabilities': {'pipeline_reliability': 0.0, 'observability': 0.0, 'pricing': 0.85, 'other': 0.15}}, none),
    (6, {'type': 'choice', 'choice': 'other', 'confidence': 0.7, 'probabilities': {'pipeline_reliability': 0.1, 'observability': 0.1, 'pricing': 0.1, 'other': 0.7}}, none),
] -%}
{%- for id, answer, err in cases %}
select
    {{ id }} as utterance_id,
    cast(null as varchar) as content_hash,
    'call_topics' as vocabulary_name,
    'v1' as vocabulary_version,
    'call_topics@v1/decide' as vocabulary_key,
    'decide' as method,
    {{ dbt_context_engineering.str_literal(tojson({
        'response': ({'answers': {'term': answer}} if answer else none),
        'metadata': {'version': '1.0'},
        'error_message': err})) }} as decision,
    cast(null as varchar) as classified_term,
    current_timestamp as decided_at
{%- if not loop.last %}
union all
{%- endif %}
{%- endfor %}

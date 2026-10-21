{{ config(materialized='incremental', unique_key='utterance_id',
          meta={'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}) }}

{#- Stand-in for vocabulary_decide's incremental model, with no AI call: exercises
    vocabulary_delta_predicate. Rows with a human review (5 and 7 in vocab_reviews) must never be
    selected for a decision, even on a first build; 8's review has no approved_term, so it is
    decided. See tests/assert_vocab_delta.sql. -#}
-- depends_on: {{ ref('vocab_reviews') }}
select
    utterance_id,
    content_hash,
    'call_topics@v1/decide' as vocabulary_key
from {{ ref('vocab_delta_stg') }}
{%- set _delta = vocab_delta_filter() %}
{%- if _delta %}
where {{ _delta }}
{%- endif %}

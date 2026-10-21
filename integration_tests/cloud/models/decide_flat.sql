{{ config(materialized='table', enabled=dbt_context_engineering.decide_available()) }}

{#- Reads every question type back out of decide()'s raw result through decide_answer. -#}
{%- set labels = decide_test_questions()['topic']['criteria'].keys() | list %}
select
    utterance_id,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'choice') }}                          as topic,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'confidence', dbt.type_float()) }}    as topic_confidence,
    {%- for l in labels %}
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'probabilities.' ~ l, dbt.type_float()) }} as p_{{ l }},
    {%- endfor %}
    {{ dbt_context_engineering.decide_answer('d', 'frustrated', 'probability', dbt.type_float()) }} as frustrated_probability,
    {{ dbt_context_engineering.decide_answer('d', 'tone', 'score', dbt.type_float()) }}            as tone_score,
    {{ dbt_context_engineering.decide_error('d') }}                                               as error
from {{ ref('decide') }}

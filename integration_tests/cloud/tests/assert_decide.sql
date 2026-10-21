{{ config(enabled=dbt_context_engineering.decide_available()) }}
-- LIVE validation of decide(): every row answered without error, the choice is one of the
-- question's labels, probabilities and confidence are in range, the per-label probabilities sum to
-- 1, and the score sits on the 0..2 scale of a three-level rubric. Fail rows only.
{%- set labels = decide_test_questions()['topic']['criteria'].keys() | list %}
select cast(utterance_id as {{ dbt.type_string() }}) as id, 'bad_answer' as issue
from {{ ref('decide_flat') }}
where error is not null
   or topic is null
   or topic not in ({% for l in labels %}'{{ l }}'{% if not loop.last %}, {% endif %}{% endfor %})
   or topic_confidence is null or topic_confidence < 0 or topic_confidence > 1
   or abs(({% for l in labels %}coalesce(p_{{ l }}, 0){% if not loop.last %} + {% endif %}{% endfor %}) - 1) > 0.01
   or frustrated_probability is null or frustrated_probability < 0 or frustrated_probability > 1
   or tone_score is null or tone_score < 0 or tone_score > 2
union all
select 'all' as id, 'wrong_row_count' as issue
from (select count(*) as n from {{ ref('decide_flat') }}) c
where c.n <> 10

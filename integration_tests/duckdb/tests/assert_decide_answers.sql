-- decide_answer / decide_error read every question type and the error path from a seeded
-- decide() result in the Databricks envelope. Fail rows only.
select id, 'wrong_success_row' as issue
from {{ ref('decide_answers_test') }}
where id = 'd1'
  and not (
        topic = 'pipeline_failure'
    and abs(topic_confidence - 0.82) < 1e-9
    and abs(p_observability - 0.1) < 1e-9
    and abs(urgent_probability - 0.71) < 1e-9
    and abs(tone_score - 1.4) < 1e-9
    and error is null
  )
union all
select id, 'wrong_error_row' as issue
from {{ ref('decide_answers_test') }}
where id = 'd2'
  and not (topic is null and urgent_probability is null and error = 'state too long')
union all
select 'missing' as id, 'missing_rows' as issue
from (select count(*) as n from {{ ref('decide_answers_test') }}) c
where c.n <> 2

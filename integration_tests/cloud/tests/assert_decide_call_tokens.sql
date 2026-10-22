{{ config(enabled=dbt_context_engineering.decide_available()) }}
-- decide's log_ai_run row counts the questions JSON on every row (it is sent with each one) and
-- no output allowance (a decision model returns typed answers, not generated text), even though this project sets
-- max_output_tokens. The per-row overhead is recomputed here from the questions text, not taken
-- from the macro under test: tojson's length, which equals decide_questions_json's, since the two
-- differ only in key order. Fail rows only. The post-hook side effect is invisible to the DAG:
-- depends_on: {{ ref('decide') }}
{%- set per_row = (((tojson(decide_test_questions()) | length) / 4) | round(0, 'ceil') | int) %}
with started as (
    select * from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and function_name = 'decide'
      and model_name = 'ai_decide'
      and event = 'started'
),
expected as (
    select
        count(*) as n_rows,
        coalesce(sum({{ dbt_context_engineering.estimate_tokens('utterance_text') }}), 0) as input_tokens
    from {{ ref('fixture_utterances') }}
)
select 'wrong_est_tokens' as issue
from started cross join expected
where started.est_tokens <> expected.input_tokens + expected.n_rows * {{ per_row }}
union all
select 'missing_started' as issue
from (select count(*) as n from started) c
where c.n <> 1

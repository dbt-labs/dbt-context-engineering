-- vocab_decided's hooks pass no prompt arguments; resolve_call_prompt reads meta.ai_vocabulary.
-- The logged est_tokens must therefore equal the estimate over the rows actually sent (every
-- fixture utterance except the reviewed one) for the text each row's call carries on this
-- engine's method: the decide questions JSON with no output allowance, or the classify prompt and
-- schema with the usual allowance. Fail rows only. The pre-hook side effect is invisible to the DAG:
-- depends_on: {{ ref('vocab_decided') }}
{%- set method = dbt_context_engineering.vocabulary_method() %}
with started as (
    select * from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and function_name = '{{ method }}'
      and model_name = 'vocab-pipeline-test'
      and event = 'started'
),
expected as (
    select
        count(*) as n_rows,
        coalesce(sum({{ dbt_context_engineering.estimate_call_tokens('utterance_text',
            dbt_context_engineering.vocabulary_sent_prompt('call_topics', 'v1'),
            dbt_context_engineering.vocabulary_sent_schema('call_topics', 'v1'),
            (0 if method == 'decide' else none)) }}), 0) as est_tokens
    from {{ ref('vocab_stg') }}
    where utterance_id not in (select utterance_id from {{ ref('vocab_reviews') }})
)
select 'wrong_est_tokens' as issue
from started cross join expected
where started.est_tokens <> expected.est_tokens or started.row_count <> expected.n_rows
union all
select 'missing_started' as issue
from (select count(*) as n from started) c
where c.n <> 1

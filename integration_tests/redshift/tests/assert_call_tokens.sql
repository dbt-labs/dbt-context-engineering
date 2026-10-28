-- logged_prompted logs an extract run with its meta.ai_prompt prompt and schema and
-- output_tokens=50. est_tokens must equal the input-text estimate plus, for every row, the prompt
-- template (placeholder removed), the schema and the output allowance (estimate_call_tokens). The per-row overhead is recomputed here
-- from the prompt text, not taken from the macro under test. On BigQuery the sent prompt includes
-- augment_prompt's enum block. Fail rows only. The post-hook side effect is invisible to the DAG:
-- depends_on: {{ ref('logged_prompted') }}
{%- set p = dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3') -%}
{%- set s = dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3') -%}
{%- set sent = dbt_context_engineering.augment_prompt(p, s) if target.type == 'bigquery' else p -%}
{%- set template = sent | replace('{{ input }}', '') -%}
{%- set per_row = ((((template | length) + (s | length)) / 4) | round(0, 'ceil') | int) + 50 %}
with started as (
    select * from {{ ref('ai_run_log') }}
    where invocation_id = '{{ invocation_id }}'
      and function_name = 'extract'
      and model_name = 'prompted-test'
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

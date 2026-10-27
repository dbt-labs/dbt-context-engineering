-- LIVE fixed-vocabulary pipeline, every engine. Utterance 4 is reviewed: never decided, and its
-- approved term wins. Every other row follows its method's contract:
--   decide (Databricks, Snowflake with decide_snowflake_preview):
--                           status accepted / needs_review; accepted means confidence >= 0.6 and
--                           final_term = term; needs_review means final_term is null.
--   classify (fallback):    no confidence; status unscored / needs_review; unscored rows still
--                           reach final_term.
-- Fail rows only.
{%- set method = dbt_context_engineering.vocabulary_method() %}
select cast(utterance_id as {{ dbt.type_string() }}) as id, 'reviewed_row_wrong' as issue
from {{ ref('vocab_labels') }}
where utterance_id = 4
  and not (final_term = 'observability' and final_status = 'reviewed')
union all
select cast(utterance_id as {{ dbt.type_string() }}), 'reviewed_row_decided'
from {{ ref('vocab_decided') }}
where utterance_id = 4
union all
select cast(utterance_id as {{ dbt.type_string() }}), 'contract_{{ method }}'
from {{ ref('vocab_labels') }}
where utterance_id <> 4
  and method <> '{{ method }}'
{%- if method == 'decide' %}
   or (utterance_id <> 4 and (
        status not in ('accepted', 'needs_review')
     or (status = 'accepted' and (confidence < 0.6 or final_term is distinct from term))
     or (status = 'needs_review' and final_term is not null)
     or decision_model is null
     {%- if target.type == 'snowflake' %}
     or decision_model <> '{{ dbt_context_engineering.decide_snowflake_model() }}'
     {%- else %}
     or decision_model not like 'ai_decide/%'
     {%- endif %}))
{%- else %}
   or (utterance_id <> 4 and (
        confidence is not null
     or status not in ('unscored', 'needs_review')
     or (status = 'unscored' and final_term is distinct from term)))
{%- endif %}
union all
select 'all', 'wrong_row_count'
from (select count(*) as n from {{ ref('vocab_labels') }}) c
where c.n <> 10

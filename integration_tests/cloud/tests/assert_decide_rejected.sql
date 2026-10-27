{{ config(enabled=(target.type == 'snowflake' and dbt_context_engineering.decide_available())) }}
-- LIVE, Snowflake only: a request Snowflake rejects surfaces its message through decide_error, and
-- no answer leaks through decide_answer. The message text is the engine's and differs by model,
-- so only its presence is asserted. Fail rows only.
select 'error_missing' as issue
from {{ ref('decide_rejected') }}
where coalesce(trim({{ dbt_context_engineering.decide_error('d') }}), '') = ''
union all
select 'answer_leaked'
from {{ ref('decide_rejected') }}
where {{ dbt_context_engineering.decide_answer('d', 'topic', 'choice') }} is not null
union all
select 'model_missing'
from {{ ref('decide_rejected') }}
where {{ dbt_context_engineering.decide_model('d') }} is distinct from '{{ dbt_context_engineering.decide_snowflake_model() }}'

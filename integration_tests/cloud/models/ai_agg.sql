{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_agg_batch(ref('fixture_utterances'), 'utterance_text', 'call_id') }}"
) }}

{#- LIVE validation of ai_agg (ADR-0028): a GROUP BY aggregate asking the model to summarize each
    call transcript in one sentence. order_column pins Databricks' internal ordering; on Snowflake
    it has no effect unless the FROM clause itself is pre-sorted (not needed here, order isn't
    load-bearing for a one-sentence summary); on BigQuery it is a confirmed no-op either way. -#}
select
    call_id,
    {{ dbt_context_engineering.ai_agg(
        'utterance_text',
        'Summarize the following call transcript in one sentence.',
        order_column='turn_index'
    ) }} as call_summary
from {{ ref('fixture_utterances') }}
group by call_id

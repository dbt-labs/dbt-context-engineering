{{ config(
    materialized='table',
    enabled=var('run_oversized_agg_probe', false),
    pre_hook="{{ dbt_context_engineering.guard_agg_batch(ref('ai_agg_oversized_input'), 'utterance_text', 'grp') }}"
) }}
{#- Oversized-group probe (hub #178). One group of 1000 rows, about 70KB of text. Disabled unless
    var run_oversized_agg_probe is true, because on engines without internal map-reduce this is
    expected to fail at the ceiling or the Redshift 64KB LISTAGG limit. The outcome per engine is
    the result being recorded, not a gate. -#}
select
    grp,
    {{ dbt_context_engineering.ai_agg(
        'utterance_text',
        'Summarize the following text in one sentence.'
    ) }} as summary
from {{ ref('ai_agg_oversized_input') }}
group by grp

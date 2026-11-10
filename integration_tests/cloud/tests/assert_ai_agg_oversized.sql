-- LIVE (only when run_oversized_agg_probe is true): the oversized group's summary must be
-- non-empty where the engine builds it. An engine that fails at its ceiling never reaches this.
{%- if var('run_oversized_agg_probe', false) %}
select grp
from {{ ref('ai_agg_oversized') }}
where summary is null or length(trim(summary)) = 0
{%- else %}
select 1 as skipped from {{ ref('fixture_utterances') }} where 1 = 0
{%- endif %}

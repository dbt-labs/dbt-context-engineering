{{ config(materialized='table', enabled=var('run_oversized_agg_probe', false)) }}
{#- 10 x 10 x 10 cross join: 1000 rows in a single group. The text varies by row so the group is
    not one repeated line. -#}
select
    'big_group' as grp,
    {{ dbt.concat(['a.utterance_text', "' / '", 'b.speaker', "' / '", 'c.speaker']) }} as utterance_text
from {{ ref('fixture_utterances') }} a
cross join {{ ref('fixture_utterances') }} b
cross join {{ ref('fixture_utterances') }} c

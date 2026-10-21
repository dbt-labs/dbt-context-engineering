{{ config(materialized='table') }}
{#- Seeded predictions with a confidence, for eval_confidence. -#}
select 'a' as pred, 'a' as expected, 0.95 as confidence
union all select 'a', 'b', 0.92
union all select 'b', 'b', 0.85
union all select 'b', 'b', 0.60
union all select 'a', 'b', 0.40
union all select 'a', 'a', null

-- eval()'s confidence buckets: accuracy and count per bucket match the seeded predictions, and a
-- bucket with no predictions emits no row. Fail rows only.
with expected as (
    select 'accuracy_by_confidence' as metric, '0.9-1.0' as label, 0.5 as value
    union all select 'count_by_confidence', '0.9-1.0', 2
    union all select 'accuracy_by_confidence', '0.8-0.9', 1.0
    union all select 'accuracy_by_confidence', '0.5-0.7', 1.0
    union all select 'accuracy_by_confidence', '0.0-0.5', 0.0
    union all select 'accuracy_by_confidence', 'unscored', 1.0
    union all select 'count_by_confidence', 'unscored', 1
)
select e.metric || ':' || e.label as issue
from expected e
left join {{ ref('eval_confidence') }} a on a.metric = e.metric and a.label = e.label
where a.value is null or abs(a.value - e.value) > 1e-9
union all
select 'unexpected_bucket:' || label from {{ ref('eval_confidence') }} where label = '0.7-0.8'

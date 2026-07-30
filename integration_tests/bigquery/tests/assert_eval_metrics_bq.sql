-- ce_eval must compute the known golden-set metrics exactly on this warehouse. Seed has 8 rows,
-- 6 correct => accuracy 0.75; 'objection' precision 1/1 = 1.0, recall 1/2 = 0.5. Fail rows only.
with m as (
    select * from {{ ref('ce_eval_metrics_bq') }}
)
select 'bad_accuracy' as issue
from m where metric = 'accuracy' and label = '__overall__' and value <> 0.75
union all
select 'bad_precision_objection'
from m where metric = 'precision' and label = 'objection' and value <> 1.0
union all
select 'bad_recall_objection'
from m where metric = 'recall' and label = 'objection' and value <> 0.5
union all
select 'bad_shape'
from (select 1 as _one) as _s
where (select count(*) from m where metric = 'accuracy') <> 1
   or (select count(*) from m where metric = 'precision') <> 5
   or (select count(*) from m where metric = 'recall') <> 5

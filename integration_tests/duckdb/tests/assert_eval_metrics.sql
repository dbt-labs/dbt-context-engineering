-- ce_eval must compute the known golden-set metrics exactly. The fixture has 8 rows, 6 correct
-- (see ce_fixture_eval): accuracy = 6/8 = 0.75. For 'objection' — predicted once (e5, correct),
-- actual twice (e5, e7) — precision = 1/1 = 1.0, recall = 1/2 = 0.5. All values are exactly
-- representable, so exact equality is safe. Returns rows only on failure.
with m as (
    select * from {{ ref('ce_eval_metrics') }}
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
-- exactly one overall accuracy row, and precision/recall present for every observed label (5).
select 'bad_shape'
from (select 1) as _one
where (select count(*) from m where metric = 'accuracy') <> 1
   or (select count(*) from m where metric = 'precision') <> 5
   or (select count(*) from m where metric = 'recall') <> 5

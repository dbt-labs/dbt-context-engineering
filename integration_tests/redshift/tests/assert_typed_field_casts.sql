-- LIVE: field(..., as_type=int/float/boolean) must yield the typed values the prompt pinned
-- (count 7, ratio 0.25, flag true). A null or wrong value means the cast path is broken for this
-- engine's result shape, or the model ignored the pinned values (behavioral, rerun to tell).
-- Fail rows only.
select *
from {{ ref('typed_flatten') }}
where count_val is null or count_val != 7
   or ratio_val is null or abs(ratio_val - 0.25) > 0.0001
   or flag_val is null or flag_val != true

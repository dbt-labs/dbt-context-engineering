-- LIVE validation of classify's best-effort output contract on Redshift: every label must be a
-- non-null member of the schema enum (bug/sales/positive/other). This is the test that would catch
-- the best-effort prompt-enforced label drifting off-taxonomy. Fail rows only.
select 'off_enum_or_null' as issue, id, signal
from {{ ref('rs_classify') }}
where signal is null
   or signal not in ('bug', 'sales', 'positive', 'other')

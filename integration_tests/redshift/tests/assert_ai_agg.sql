-- LIVE validation of ai_agg: the per-group summary must be non-empty on every engine.
select call_id
from {{ ref('ai_agg') }}
where call_summary is null or length(trim(call_summary)) = 0

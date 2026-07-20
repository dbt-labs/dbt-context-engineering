-- Cross-source, account-scoped retrieval: query [1,0,0] over acme's KB rows should rank the
-- ticket t1 (identical) then the call c1 (near) — spanning two source systems — exclude globex
-- (filter), preserve source_type lineage, and return exactly 2 rows. Returns rows only on failure.
with ranked as (
    select source_id, source_type, account_key, score,
           row_number() over (order by score desc) as rn
    from {{ ref('ce_kb_search') }}
)
select 'wrong_top' as issue
from ranked where rn = 1 and (source_id <> 't1' or source_type <> 'ticket')

union all
select 'wrong_second' as issue
from ranked where rn = 2 and (source_id <> 'c1' or source_type <> 'call')

union all
select 'filter_leak' as issue
from ranked where account_key <> 'acme'

union all
select 'wrong_count' as issue
from {{ ref('ce_kb_search') }} having count(*) <> 2

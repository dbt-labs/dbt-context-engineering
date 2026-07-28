-- Cross-source, account-scoped retrieval: query [1,0,0] over acme's KB rows should rank the
-- ticket t1 (identical) then the call c1 (near) — spanning two source systems — exclude globex
-- (filter), preserve source_type lineage, and return exactly 2 rows. citation_url is optional
-- per source (see ce_kb.sql: tickets have it, calls don't) — confirm that optionality survives
-- ce_vector_search's select_columns passthrough too, not just the knowledge-base union. Returns
-- rows only on failure.
with ranked as (
    select source_id, source_type, account_key, citation_url, score,
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
select 'ticket_missing_citation' as issue
from ranked where source_type = 'ticket' and citation_url is null

union all
select 'call_citation_should_be_null' as issue
from ranked where source_type = 'call' and citation_url is not null

union all
select 'wrong_count' as issue
from {{ ref('ce_kb_search') }} having count(*) <> 2

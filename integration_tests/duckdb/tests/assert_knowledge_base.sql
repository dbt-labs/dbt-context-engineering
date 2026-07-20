-- ce_knowledge_base must unify both sources into the common shape with lineage intact:
-- 4 rows, 2 source_types, no null lineage/text/embedding. Returns rows only on failure.
with kb as (
    select * from {{ ref('ce_kb') }}
)
select 'bad_count' as issue
from kb having count(*) <> 4

union all
select 'bad_source_types' as issue
from kb having count(distinct source_type) <> 2

union all
select 'null_field' as issue
from kb
where source_type is null or source_id is null or account_key is null
   or text is null or embedding is null or ts is null

-- knowledge_base heterogeneous-ts union (#8): both sources unify to a common timestamp type — the
-- DATE source lands at midnight, the TIMESTAMP source unchanged — and the mixed-type UNION builds at
-- all. Row count = 2x the embeddings rows. Fail rows only.
with kb as (select * from {{ ref('kb_hetero_sf') }})
select 'bad_count' as issue
from (select count(*) as n from kb) c
where c.n <> 2 * (select count(*) from {{ ref('embeddings_sf') }})

union all
select 'date_src_not_midnight' as issue
from kb where source_type = 'date_src'
  and ts <> cast(cast('2026-01-03' as date) as {{ dbt.type_timestamp() }})

union all
select 'ts_src_changed' as issue
from kb where source_type = 'ts_src'
  and ts <> cast('2026-01-01 10:00:00' as {{ dbt.type_timestamp() }})

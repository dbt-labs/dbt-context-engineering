-- Validates knowledge_base union + common-shape + per-source lineage on this warehouse. Two
-- logical sources over the 10-row embedded fixture => 20 mart rows spanning both source types, all
-- rows carrying non-null lineage/shape. classification is source-configured optional (see kb.sql)
-- -- 'call' supplies it, 'ticket' omits it -- so this checks both branches. Fail rows only.
with kb as (
    select * from {{ ref('kb') }}
)
select 'bad_row_count' as issue
from (select count(*) as n from kb) c where c.n <> 20
union all
select 'missing_source_type' as issue
from (select count(distinct source_type) as d from kb) c where c.d <> 2
union all
select 'null_lineage_or_shape' as issue
from kb
where source_id is null or account_key is null or embedding is null or text is null or source_type is null
union all
select 'classification_should_be_present' as issue
from kb where source_type = 'call' and classification is null
union all
select 'classification_should_be_null' as issue
from kb where source_type = 'ticket' and classification is not null

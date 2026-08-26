-- knowledge_base must unify both sources into the common shape with lineage intact:
-- 4 rows, 2 source_types, no null lineage/text/embedding. citation_url and classification are
-- each source-configured optional (see kb.sql): tickets supply both, calls omit both, so this
-- checks BOTH branches for each: present-key rows must be non-null, omitted-key rows must be
-- exactly null (not empty string, not some other placeholder). Returns rows only on failure.
with kb as (
    select * from {{ ref('kb') }}
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

union all
select 'citation_url_should_be_present' as issue
from kb where source_type = 'ticket' and citation_url is null

union all
select 'citation_url_should_be_null' as issue
from kb where source_type = 'call' and citation_url is not null

union all
select 'classification_should_be_present' as issue
from kb where source_type = 'ticket' and classification is null

union all
select 'classification_should_be_null' as issue
from kb where source_type = 'call' and classification is not null

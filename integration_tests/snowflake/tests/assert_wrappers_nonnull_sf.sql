-- LIVE liveness check: every AI wrapper must actually PRODUCE output on this warehouse (a null
-- result means the call silently failed — e.g. content filter, bad endpoint, empty response —
-- which a plain build would not catch). Fail rows only.
select 'generate_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('generate_sf') }} where result is null
union all
select 'classify_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('signals_sf') }} where signal is null
union all
select 'extract_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('extract_sf') }} where extracted is null
union all
select 'embed_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('embeddings_sf') }} where embedding is null

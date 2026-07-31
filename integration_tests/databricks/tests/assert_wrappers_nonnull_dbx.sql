-- LIVE liveness check: every AI wrapper must actually PRODUCE output on this warehouse (a null
-- result means the call silently failed — e.g. content filter, bad endpoint, empty response —
-- which a plain build would not catch). Fail rows only.
select 'generate_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('ce_generate_dbx') }} where result is null
union all
select 'classify_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('ce_signals_dbx') }} where signal is null
union all
select 'extract_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('ce_extract_dbx') }} where extracted is null
union all
select 'embed_null' as issue, cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('ce_embeddings_dbx') }} where embedding is null

-- LIVE: every embedding must be a non-empty vector. embed() can fail silently with an empty array
-- in place of a null (seen on BigQuery's AI.EMBED under throttling), and the embeddings model still
-- reports success. Downstream, that surfaces only as an opaque dimension mismatch in search. A
-- failure here is a rebuild-and-retest case (TESTING.md section 5). Fail rows only.
select
    case when embedding is null then 'embed_null' else 'embed_empty' end as issue,
    cast(utterance_id as {{ dbt.type_string() }}) as id
from {{ ref('embeddings') }}
where embedding is null
   or {{ dbt_context_engineering.embedding_dimension('embedding') }} = 0

-- LIVE validation of embed (SUPER vector extraction), embedding_dimension (get_array_length), and
-- content_hash (sha2 -> 64-char hex). amazon.titan-embed-text-v2:0 returns 1024-dim by default.
-- Fail rows only.
select 'wrong_dim' as issue, id
from {{ ref('rs_embeddings') }}
where dim <> 1024
union all
select 'null_embedding' as issue, id
from {{ ref('rs_embeddings') }}
where embedding is null or {{ dbt_context_engineering.embedding_dimension('embedding') }} <> dim
union all
select 'bad_content_hash' as issue, id
from {{ ref('rs_embeddings') }}
where content_hash is null or len(content_hash) <> 64

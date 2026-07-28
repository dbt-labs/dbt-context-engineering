-- frontmatter_columns with default frontmatter_in_text=False: title/citation_url must be present
-- on every chunk, must match the source document, and must NOT be injected into chunk_text.
-- Returns rows only on failure.
with chunks as (
    select * from {{ ref('ce_chunk_frontmatter_cols') }}
),
docs as (
    select * from {{ ref('ce_fixture_documents') }}
)
select 'missing_frontmatter' as issue, chunk_id
from chunks
where title is null or citation_url is null

union all

select 'wrong_frontmatter' as issue, c.chunk_id
from chunks c
join docs d on c.partition_key = d.document_id
where c.title <> d.title or c.citation_url <> d.citation_url

union all

select 'frontmatter_leaked_into_text' as issue, chunk_id
from chunks
where chunk_text like '---%' or chunk_text like 'title:%'

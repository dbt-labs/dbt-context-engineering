-- frontmatter_columns must survive the overlap-duplication path (_ce_exploded's second branch)
-- unchanged: a sentence duplicated into two adjacent chunks must carry identical title/
-- citation_url in both, and every chunk must still have non-null frontmatter. Also confirms
-- overlap actually happened on this fixture (otherwise the test proves nothing). Fail rows only.
with exploded as (
    select c.chunk_seq, c.title, c.citation_url, unnest(c.source_rows) as sentence_id
    from {{ ref('ce_chunk_frontmatter_overlap') }} c
),
per_sentence as (
    select sentence_id, count(*) as appearances,
           count(distinct title) as distinct_titles,
           count(distinct citation_url) as distinct_urls
    from exploded
    group by sentence_id
)
select 'no_duplication_present' as issue
from per_sentence having max(appearances) <= 1

union all

select 'frontmatter_diverged_across_duplicate' as issue
from per_sentence
where appearances > 1 and (distinct_titles > 1 or distinct_urls > 1)

union all

select 'missing_frontmatter' as issue
from {{ ref('ce_chunk_frontmatter_overlap') }}
where title is null or citation_url is null

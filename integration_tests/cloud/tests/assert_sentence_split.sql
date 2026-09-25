-- Exact split_sentences output over the document seed. Fail rows only: validates sentence count,
-- 1-based contiguous index, and verbatim text per document.
with expected as (
    select 'doc_1' as document_id, 1 as sentence_index, 'Data pipelines break often.' as sentence_text
    union all select 'doc_1', 2, 'Observability is the core need!'
    union all select 'doc_1', 3, 'Can we see which model failed?'
    union all select 'doc_2', 1, 'The nightly load is slow.'
    union all select 'doc_2', 2, 'It needs to finish before the morning refresh.'
    union all select 'doc_3', 1, 'A single sentence document with no terminator'
),
produced as (
    select document_id, sentence_index, sentence_text from {{ ref('split_docs') }}
)
select
    coalesce(p.document_id, e.document_id)       as document_id,
    coalesce(p.sentence_index, e.sentence_index) as sentence_index,
    p.sentence_text                              as produced,
    e.sentence_text                              as expected
from produced p
full outer join expected e
    on p.document_id = e.document_id and p.sentence_index = e.sentence_index
where p.sentence_text is distinct from e.sentence_text

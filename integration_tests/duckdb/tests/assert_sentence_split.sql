-- Exact ce_split_sentences output over the document seed. Returns rows only on mismatch:
-- validates sentence count, 1-based contiguous index, and verbatim text per document.
with produced as (
    select document_id, sentence_index, sentence_text
    from {{ ref('ce_split_docs') }}
),
expected(document_id, sentence_index, sentence_text) as (
    values
        ('doc_1', 1, 'Data pipelines break often.'),
        ('doc_1', 2, 'Observability is the core need!'),
        ('doc_1', 3, 'Can we see which model failed?'),
        ('doc_2', 1, 'The nightly load is slow.'),
        ('doc_2', 2, 'It needs to finish before the morning refresh.'),
        ('doc_3', 1, 'A single sentence document with no terminator')
)
select
    coalesce(p.document_id, e.document_id) as document_id,
    coalesce(p.sentence_index, e.sentence_index) as sentence_index,
    p.sentence_text as produced,
    e.sentence_text as expected
from produced p
full outer join expected e
    on p.document_id = e.document_id and p.sentence_index = e.sentence_index
where p.sentence_text is distinct from e.sentence_text

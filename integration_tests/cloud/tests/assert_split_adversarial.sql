-- Cross-engine parity of split_sentences (#7): the sentence SET must match this golden exactly on
-- every warehouse. The Snowflake impl historically used a different (whitespace-only) boundary rule,
-- so "Section 3.2 is ready." stayed one sentence there while the other engines split it three ways —
-- a silent divergence this golden catches live. Golden computed from the canonical
-- regexp_extract_all('[^.!?]+[.!?]*') rule. Fail rows only (tuples on one side but not the other).
with expected as (
    select 'a1' as document_id, 1 as sentence_index, 'Section 3.' as sentence_text
    union all select 'a1', 2, '2 is ready.'
    union all select 'a1', 3, 'Ship it.'
    union all select 'a2', 1, 'Wait!?'
    union all select 'a2', 2, 'Really'
    union all select 'a3', 1, 'go now.'
),
actual as (
    select document_id, sentence_index, sentence_text from {{ ref('split_adversarial') }}
)
select coalesce(e.document_id, a.document_id) as document_id,
       coalesce(e.sentence_index, a.sentence_index) as sentence_index
from expected e
full outer join actual a
  on e.document_id = a.document_id
 and e.sentence_index = a.sentence_index
 and e.sentence_text = a.sentence_text
where e.document_id is null or a.document_id is null

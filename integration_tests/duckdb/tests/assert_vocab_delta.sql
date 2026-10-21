-- vocabulary_delta_predicate never sends a reviewed row to the model: utterances 5 and 7 have an
-- approved_term in vocab_reviews and must be absent; every other fixture utterance is present.
-- Fail rows only.
select utterance_id, 'reviewed_row_decided' as issue
from {{ ref('vocab_delta_standin') }}
where utterance_id in (5, 7)
union all
select 0, 'wrong_row_count'
from (select count(*) as n from {{ ref('vocab_delta_standin') }}) c
where c.n <> 8

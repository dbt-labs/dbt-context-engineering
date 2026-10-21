-- vocabulary_labels on the classify fallback: an active term is 'unscored' and still reaches
-- final_term; a label outside the vocabulary goes to review. No confidence or runner-up. Fail rows only.
select utterance_id, 'mismatch' as issue
from {{ ref('vocab_labels_classify') }}
where confidence is not null
   or runner_up is not null
   or (utterance_id = 1 and not (status = 'unscored' and final_term = 'pricing' and final_status = 'unscored'))
   or (utterance_id = 2 and not (status = 'needs_review' and final_term is null))
union all
select 0, 'row_count' from (select count(*) as n from {{ ref('vocab_labels_classify') }}) c where c.n <> 2

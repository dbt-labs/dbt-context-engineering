-- vocabulary_labels on the decide path: confidence routing at the 0.7 threshold, runner-up
-- ranking (most probable active term other than the choice), terms outside the active vocabulary sent to review, and the latest human review winning
-- over the model (including a reviewed row that was never decided). Fail rows only.
with expected as (
    select 1 as utterance_id, 'pipeline_reliability' as term, 'observability' as runner_up, 'accepted' as status, cast(null as varchar) as approved_term, 'pipeline_reliability' as final_term, 'accepted' as final_status
    union all select 2, 'observability',  'pipeline_reliability', 'needs_review', null,      null,                   'needs_review'
    union all select 3, null,             null,                   'needs_review', null,      null,                   'needs_review'
    union all select 4, 'legacy_tooling', 'pipeline_reliability', 'needs_review', null,      null,                   'needs_review'
    union all select 5, 'pricing',        'other',                'accepted',     'other',   'other',                'reviewed'
    union all select 6, 'other',          null,                   'accepted',     null,      'other',                'accepted'
    union all select 7, null,             null,                   null,           'pricing', 'pricing',              'reviewed'
)
select e.utterance_id, 'mismatch' as issue
from expected e
left join {{ ref('vocab_labels_decide') }} a on a.utterance_id = e.utterance_id
where a.utterance_id is null
   or a.term is distinct from e.term
   or a.status is distinct from e.status
   or a.approved_term is distinct from e.approved_term
   or a.final_term is distinct from e.final_term
   or a.final_status is distinct from e.final_status
   or (e.utterance_id <> 6 and a.runner_up is distinct from e.runner_up)
union all
-- row 6: the three non-chosen labels tie at 0.1; the runner-up is the alphabetically first
select 6, 'tie_break' from {{ ref('vocab_labels_decide') }} where utterance_id = 6 and runner_up <> 'observability'
union all
select utterance_id, 'decision_model' from {{ ref('vocab_labels_decide') }}
where utterance_id <= 6 and decision_model <> 'ai_decide/1.0'
union all
select utterance_id, 'error_text' from {{ ref('vocab_labels_decide') }}
where (utterance_id = 3 and error is distinct from 'state too long') or (utterance_id <> 3 and error is not null)
union all
select 0, 'row_count' from (select count(*) as n from {{ ref('vocab_labels_decide') }}) c where c.n <> 7

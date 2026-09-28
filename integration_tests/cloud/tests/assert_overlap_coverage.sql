-- Overlap lineage invariant: every input utterance appears in AT LEAST one chunk, since overlap
-- duplicates boundary units rather than dropping them, and all 10 seed utterances are covered.
-- The complement of assert_lineage_exactly_once, which pins the overlap=0 case at exactly one.
-- Fail rows only.
with per_utterance as (
    select u.utterance_id, count(c.chunk_id) as appearances
    from {{ ref('fixture_utterances') }} u
    left join {{ ref('chunk_overlap') }} c
        on {{ t_arr_has('c.source_rows', 'u.utterance_id') }}
    group by u.utterance_id
)

select
    'not_covered'                                 as failure,
    cast(utterance_id as {{ dbt.type_string() }}) as detail,
    appearances
from per_utterance
where appearances < 1

union all

select
    'coverage_mismatch',
    'distinct_utterances',
    count(*)
from per_utterance
having count(*) <> 10

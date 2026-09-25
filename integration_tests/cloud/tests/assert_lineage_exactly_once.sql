-- LINEAGE INVARIANT at overlap=0: every input utterance appears in exactly one chunk's
-- source_rows, and all 10 seed utterances are covered. Fail rows only.
--
-- Counted by joining the source to the chunks on array membership rather than exploding
-- source_rows, so the same file runs on all four engines.
with per_utterance as (
    select u.utterance_id, count(c.chunk_id) as appearances
    from {{ ref('fixture_utterances') }} u
    left join {{ ref('chunk_utterances') }} c
        on {{ t_arr_has('c.source_rows', 'u.utterance_id') }}
    group by u.utterance_id
)

select
    'wrong_appearance_count'                            as failure,
    cast(utterance_id as {{ dbt.type_string() }})       as detail,
    appearances
from per_utterance
where appearances <> 1

union all

select
    'coverage_mismatch',
    'distinct_utterances',
    count(*)
from per_utterance
having count(*) <> 10

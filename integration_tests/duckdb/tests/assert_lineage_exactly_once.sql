-- LINEAGE INVARIANT (overlap=0): every input utterance appears in exactly one chunk's
-- source_rows, and all 10 seed utterances are covered. Returns rows only on failure.
with exploded as (
    select unnest(source_rows) as utterance_id
    from {{ ref('chunk_utterances') }}
),
per_utterance as (
    select utterance_id, count(*) as appearances
    from exploded
    group by utterance_id
)
select 'wrong_appearance_count' as failure, cast(utterance_id as varchar) as detail, appearances
from per_utterance
where appearances <> 1

union all

select 'coverage_mismatch' as failure, 'distinct_utterances' as detail, count(*) as appearances
from per_utterance
having count(*) <> 10

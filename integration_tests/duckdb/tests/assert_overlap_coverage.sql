-- Overlap lineage invariant: every input utterance appears in AT LEAST one chunk (>=1, since
-- overlap duplicates boundary units), and all 10 seed utterances are covered. Fail rows only.
with exploded as (
    select unnest(source_rows) as utterance_id
    from {{ ref('chunk_overlap') }}
),
per_utterance as (
    select utterance_id, count(*) as appearances
    from exploded
    group by utterance_id
)
select 'not_covered_or_negative' as failure, cast(utterance_id as varchar) as detail, appearances
from per_utterance
where appearances < 1

union all

select 'coverage_mismatch' as failure, 'distinct_utterances' as detail, count(*) as appearances
from per_utterance
having count(*) <> 10

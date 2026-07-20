-- ce_versioned must carry the currently-pinned version on every row, with one row per
-- utterance_id (unique_key merge — no duplicates) and full seed coverage. Fail rows only.
with v as (
    select * from {{ ref('ce_versioned') }}
)
select 'wrong_version' as issue
from v
where model_version <> '{{ var("ce_test_version", "v1") }}'

union all

select 'bad_count_or_dupes' as issue
from v
having count(*) <> (select count(*) from {{ ref('ce_fixture_utterances') }})
    or count(distinct utterance_id) <> count(*)

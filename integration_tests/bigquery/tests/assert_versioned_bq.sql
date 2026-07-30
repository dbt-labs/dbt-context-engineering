{{ config(tags=['version_guard']) }}
-- Every row must carry the currently-pinned version, one row per utterance_id, full seed coverage.
-- Run by the multi-run CI step with ce_test_version = v1 (delta) then v2 (bump). Fail rows only.
-- Counts are aggregated in a subquery (not HAVING) so it is portable — BigQuery rejects HAVING
-- without a GROUP BY / aggregate in the SELECT list.
with v as (
    select * from {{ ref('ce_versioned_bq') }}
),
counts as (
    select count(*) as n_rows, count(distinct utterance_id) as n_ids from v
)
select 'wrong_version' as issue
from v
where model_version <> '{{ var("ce_test_version", "v1") }}'
union all
select 'bad_count_or_dupes' as issue
from counts
where n_rows <> (select count(*) from {{ ref('ce_fixture_utterances') }})
   or n_ids <> n_rows

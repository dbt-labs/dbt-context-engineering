-- guard_delta must carry one row per utterance_id with full seed coverage after the
-- delta-guarded incremental build (no rows dropped by the scoped guard/filter). Fail rows only.
select 'bad_count_or_dupes' as issue
from {{ ref('guard_delta') }}
having count(*) <> (select count(*) from {{ ref('fixture_utterances') }})
    or count(distinct utterance_id) <> count(*)

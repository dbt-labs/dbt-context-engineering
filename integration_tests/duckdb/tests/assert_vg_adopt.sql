-- version_guard adoption (finding #9): after an incremental run, vg_adopt must carry the pinned
-- version on every row with full coverage and no dupes. This invariant holds both for a plain first
-- build and after the legacy->adoption sequence (CI "version_guard adopts a pre-existing table"),
-- so it passes in the normal build and would fail if adoption silently dropped/failed to stamp rows.
-- The decisive proof that adoption doesn't ERROR is the CI step's exit code; this pins the result.
-- Fail rows only.
select 'bad_version_or_null' as issue
from {{ ref('vg_adopt') }}
where model_version is distinct from '{{ var("vg_ver", "v1") }}'

union all
select 'bad_count_or_dupes' as issue
from {{ ref('vg_adopt') }}
having count(*) <> (select count(*) from {{ ref('fixture_utterances') }})
    or count(distinct utterance_id) <> count(*)

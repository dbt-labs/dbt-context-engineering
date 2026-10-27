-- chunk()'s partition-level incremental mechanism. Returns rows only on violation.
--
-- Ordered two-phase test, same contract as assert_content_hash_delta:
--   phase 1   dbt build --full-refresh              (cd_phase unset)
--   phase 2   dbt build --vars '{cd_phase: 2}'      (NO --full-refresh, directly after phase 1)
--
-- Phase 2 grows one partition, shrinks another so a chunk is vacated, and introduces a third.
-- See chunk_delta_units for the fixture and chunk_delta for the materialization.
--
-- Phase 1 REQUIRES --full-refresh, and the reason is a real property worth knowing rather than a
-- fixture quirk. Running phase 1 incrementally over a phase-2 table leaves the `new` partition
-- behind: it is absent from the source, so it produces no rows, so no incremental strategy keyed
-- on the partitions PRESENT IN THE INCOMING DATA ever deletes it. Reproduced on Snowflake and
-- Databricks (5 rows, `new` surviving with 1 chunk); BigQuery is immune only because chunk_delta
-- is a table there. A partition deleted from source outlives its chunks until a full refresh.
--
-- Every branch below uses HAVING for its aggregate comparisons on purpose: a bare aggregate with
-- no HAVING returns one row even over empty input, which would make the branch fire
-- unconditionally.
--
-- depends_on: {{ ref('chunk_delta') }}

{% set phase = var('cd_phase', 1) | int %}

{% if phase == 2 %}

-- shrink drops from 3 units to 2, collapsing its two chunks into one. The vacated chunk must be
-- DELETED. This is the assertion that fails under a merge on partition_key, which updates both
-- stored rows to the incoming row's values and leaves a duplicate behind while reporting success.
select 'orphan_chunk_survived_shrink' as issue,
       cast(count(*) as {{ dbt.type_string() }}) as detail
from {{ ref('chunk_delta') }}
where partition_key = 'shrink'
having count(*) <> 1

union all

-- grow gains a unit. Its single chunk must be replaced in place, not duplicated.
select 'grow_not_replaced_in_place', {{ t_arr_csv('source_rows') }}
from {{ ref('chunk_delta') }}
where partition_key = 'grow'
  and {{ t_arr_csv('source_rows') }} <> 'g1,g2,g3'

union all

select 'grow_duplicated', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('chunk_delta') }}
where partition_key = 'grow'
having count(*) <> 1

union all

-- A brand-new partition needs no special-casing; it falls out of the same hash comparison.
select 'new_partition_missing', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('chunk_delta') }}
where partition_key = 'new'
having count(*) <> 1

union all

-- The whole table, so a stale partition left behind anywhere shows up as a count mismatch.
select 'unexpected_total_rows', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('chunk_delta') }}
having count(*) <> 4

{% if target.type != 'bigquery' %}
union all

-- clean's units never changed, so its partition hash still matches and it must have been SKIPPED,
-- keeping phase 1's built_at. Rewriting it with identical content would still be correct output,
-- but it would mean the delta filter is not actually narrowing the batch, so this is the assertion
-- that the mechanism does what it exists to do.
--
-- Not asserted on BigQuery, and not an untested gap there: BigQuery has no correct incremental
-- path for this shape (merge silently duplicates on shrink, insert_overwrite cannot partition on
-- a STRING key, delete+insert is unimplemented), so chunk_delta is materialized as a table there
-- and every partition is rebuilt by design. The correctness branches above still run on BigQuery.
-- Row-level, not aggregated, for the empty-input reason noted at the top.
select 'clean_partition_was_rewritten', cast(c.built_at as {{ dbt.type_string() }})
from {{ ref('chunk_delta') }} c
where c.partition_key = 'clean'
  and c.built_at >= (
      select min(d.built_at) from {{ ref('chunk_delta') }} d where d.partition_key <> 'clean'
  )
{% endif %}

{% else %}

-- Phase 1 baseline: shrink still holds three units across two chunks, and nothing else exists yet.
select 'baseline_shrink_chunk_count' as issue,
       cast(count(*) as {{ dbt.type_string() }}) as detail
from {{ ref('chunk_delta') }}
where partition_key = 'shrink'
having count(*) <> 2

union all

select 'baseline_total_rows', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('chunk_delta') }}
having count(*) <> 4

union all

select 'baseline_new_partition_should_not_exist', cast(count(*) as {{ dbt.type_string() }})
from {{ ref('chunk_delta') }}
where partition_key = 'new'
having count(*) <> 0

{% endif %}

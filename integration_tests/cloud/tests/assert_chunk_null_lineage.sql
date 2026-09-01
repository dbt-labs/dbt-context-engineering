-- ADR-0011: a chunk must not claim lineage its text cannot support.
-- Returns rows only on violation.
--
-- A NULL text unit is the case that breaks this silently. `label || ': ' || text` is NULL on every
-- engine when text is NULL, and an ordered string agg then drops the unit from chunk_text
-- entirely, not even leaving a separator, while source_rows and n_source_rows still count it.
-- source_rows would then name a unit with no trace in the text, and with a label the speaker
-- attribution disappears too. chunk() coalesces before assembly so the unit survives as an empty
-- (or label-only) contribution.
--
-- Asserted as exact lengths rather than "is not null", because the unlabeled null unit contributes
-- zero characters of its own and is detectable ONLY as the separator it leaves behind. A
-- not_null check on chunk_text passes either way and proves nothing.

-- Unlabeled: n1(40) + sep(1) + n2('') + sep(1) + n3(40) = 82. Without the coalesce n2 leaves no
-- separator at all and the length is 81.
select 'null_unit_dropped_from_text' as issue,
       cast(length(chunk_text) as {{ dbt.type_string() }}) as detail
from {{ ref('chunk_edges') }}
where partition_key = 'null_mid' and length(chunk_text) <> 82

union all

-- Labeled: 'S: '+40 (43) + sep + 'S: ' (3) + sep + 'S: '+40 (43) = 91. The 3 characters for the
-- null unit are the speaker attribution surviving; without the coalesce it is 87.
select 'null_unit_lost_its_label',
       cast(length(chunk_text) as {{ dbt.type_string() }})
from {{ ref('chunk_edges_labeled') }}
where partition_key = 'null_mid' and length(chunk_text) <> 91

union all

-- An all-NULL partition still produces a chunk whose text is the separator between two empty
-- units. Without the coalesce the aggregate returns NULL, which also nulls token_estimate,
-- exceeds_target, and partition_hash, so that partition drops out of delta detection entirely.
select 'all_null_partition_collapsed',
       cast(coalesce(cast(length(chunk_text) as {{ dbt.type_string() }}), 'NULL') as {{ dbt.type_string() }})
from {{ ref('chunk_edges') }}
where partition_key = 'all_null'
  and (chunk_text is null or length(chunk_text) <> 1)

union all

-- The invariant behind all of the above, stated directly: every unit in the source appears in
-- some chunk's source_rows for its partition, so no unit is silently dropped from lineage either.
select 'unit_missing_from_lineage', u.unit_id
from {{ ref('chunk_edge_units') }} u
where not exists (
    select 1
    from {{ ref('chunk_edges') }} c
    where c.partition_key = u.pk
      and {{ t_arr_has('c.source_rows', 'u.unit_id') }}
)

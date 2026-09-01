{{ config(materialized='table') }}

{#- Two-phase unit fixture for chunk()'s partition-level incremental mechanism, switched with
    var cd_phase (same shape as content_hash_delta's ch_edit_id pattern).

      phase 1 (default)   clean(c1,c2)  grow(g1,g2)     shrink(s1,s2,s3)
      phase 2             clean(c1,c2)  grow(+g3)       shrink(-s3)        new(n1,n2)

    Each partition isolates one behaviour at a 20-token budget (24-char unit = 6 tokens,
    44-char = 11):
      clean   never changes, so it must not be rewritten in phase 2
      grow    gains a unit, its single chunk must be replaced in place, not duplicated
      shrink  loses a unit, collapsing 2 chunks to 1. The vacated chunk must be DELETED, which
              is the case a merge on partition_key silently gets wrong (it updates both stored
              rows to the incoming row instead, leaving a duplicate)
      new     appears for the first time, needing no special-casing

    Run phase 2 WITHOUT --full-refresh directly after phase 1. See assert_chunk_delta. -#}

{%- set phase2 = var('cd_phase', 1) | int == 2 -%}

select 'c1' as unit_id, 1 as turn_index, 'clean' as pk, repeat('c', 24) as unit_text
union all select 'c2', 2, 'clean', repeat('d', 24)

union all select 'g1', 1, 'grow', repeat('g', 24)
union all select 'g2', 2, 'grow', repeat('h', 24)
{%- if phase2 %}
union all select 'g3', 3, 'grow', repeat('i', 24)
{%- endif %}

union all select 's1', 1, 'shrink', repeat('s', 44)
union all select 's2', 2, 'shrink', repeat('t', 44)
{%- if not phase2 %}
union all select 's3', 3, 'shrink', repeat('u', 44)
{%- endif %}

{%- if phase2 %}
union all select 'n1', 1, 'new', repeat('n', 24)
union all select 'n2', 2, 'new', repeat('o', 24)
{%- endif %}

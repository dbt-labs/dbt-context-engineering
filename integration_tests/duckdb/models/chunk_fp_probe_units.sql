{{ config(materialized='table') }}
{#- ADR-0029 verification fixture: confirms the downstream embed() no-op across a fingerprint
    change, end to end, not just reasoned from determinism. unit_id_alias holds the exact same
    values as unit_id under a different column name; passing id_column=unit_id_alias to chunk()
    changes chunk_fn_fingerprint (id_column is hashed by name) without changing any actual
    output chunk() produces, since the aliased column resolves to identical values. This
    isolates a pure fingerprint bump from a real content change, the case chunk_delta's own
    fixture doesn't exercise (every one of its phase-2 edits is a real content change). -#}
select 'u1' as unit_id, 'u1' as unit_id_alias, 'p1' as partition_key, 1 as turn_index, 'alpha bravo charlie delta echo' as unit_text
union all select 'u2', 'u2', 'p1', 2, 'foxtrot golf hotel india juliet'
union all select 'u3', 'u3', 'p2', 1, 'kilo lima mike november oscar'

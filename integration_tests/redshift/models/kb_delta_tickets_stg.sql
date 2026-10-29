{{ config(materialized='view') }}
{#- Two-phase fixture (var kbd_phase), reusing embeddings' already-paid-for vectors
    (no new AI spend). Phase 2: 't2's text is edited, 't3' appears for the first time, 't1' is
    untouched. synth_id maps embeddings' real utterance_id onto the same t1/t2/t3 ids
    kb_delta_units.sql uses on duckdb, so assert_kb_delta.sql is byte-identical in both projects. -#}
select
    case cast(utterance_id as {{ dbt.type_string() }})
        when '1' then 't1'
        when '2' then 't2'
        when '3' then 't3'
    end as synth_id,
    call_id,
    case when cast(utterance_id as {{ dbt.type_string() }}) = '2' and {{ var('kbd_phase', 1) | int }} = 2
         then utterance_text || ' (revised)'
         else utterance_text
    end as utterance_text,
    embedding
from {{ ref('embeddings') }}
where cast(utterance_id as {{ dbt.type_string() }}) in ('1', '2'{{ ", '3'" if var('kbd_phase', 1) | int == 2 else "" }})

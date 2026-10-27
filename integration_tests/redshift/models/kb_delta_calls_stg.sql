{{ config(materialized='view') }}
{#- Fixed control fixture, paired with kb_delta_tickets_stg. Never edited: proves a whole
    untouched source arm is skipped, not just individual untouched rows within a touched one.
    synth_id 'c1' matches kb_delta_units.sql's literal on duckdb, for byte-identical tests. -#}
select
    'c1' as synth_id,
    call_id,
    utterance_text,
    embedding
from {{ ref('embeddings') }}
where cast(utterance_id as {{ dbt.type_string() }}) = '7'

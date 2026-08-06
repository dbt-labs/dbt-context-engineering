{{ config(materialized='table') }}
{#- attach_metadata over the transcript pipeline on Snowflake: same macro, same call shape
    as chunk_metadata_sf, pointed at a structurally different source. customer/participants
    are frontmatter (relational, call-level metadata); recording_url is provenance (a resolvable
    link back to the call). -#}
{{ dbt_context_engineering.attach_metadata(
    chunks_relation=ref('chunk_utterances_sf'),
    metadata_relation=ref('fixture_calls'),
    metadata_key_column='call_id',
    metadata_columns=[
        'customer', 'participants',
        'recording_url'
    ]
) }}

{{ config(materialized='table') }}
{#- ce_attach_metadata over the transcript pipeline on Databricks: same macro, same call shape
    as ce_chunk_metadata_dbx, pointed at a structurally different source. customer/participants
    are frontmatter (relational, call-level metadata); recording_url is provenance (a resolvable
    link back to the call). -#}
{{ dbt_context_engineering.ce_attach_metadata(
    chunks_relation=ref('ce_chunk_utterances_dbx'),
    metadata_relation=ref('ce_fixture_calls'),
    metadata_key_column='call_id',
    metadata_columns=[
        'customer', 'participants',
        'recording_url'
    ]
) }}

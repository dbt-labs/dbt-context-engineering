{{ config(materialized='table') }}
{#- attach_metadata over chunk_docs, joined against amd_null_meta_source instead of
    fixture_documents: proves a consistently-null metadata value flows through cleanly (no
    fan-out, well-defined content_hash) rather than assuming it from the DISTINCT-collapse
    docstring alone. in_text=False: columns only. -#}
{{ dbt_context_engineering.attach_metadata(
    chunks_relation=ref('chunk_docs'),
    metadata_relation=ref('amd_null_meta_source'),
    metadata_key_column='document_id',
    metadata_columns=['title', 'citation_url']
) }}

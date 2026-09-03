{{ config(materialized='table') }}
{#- Same as amd_null_meta but in_text=True: proves a null metadata value renders as an empty
    line in the prepended block ("title: \n"), not a literal "None"/"null" string, and that the
    block is still prepended at all when every value is null. -#}
{{ dbt_context_engineering.attach_metadata(
    chunks_relation=ref('chunk_docs'),
    metadata_relation=ref('amd_null_meta_source'),
    metadata_key_column='document_id',
    metadata_columns=['title', 'citation_url'],
    in_text=true
) }}

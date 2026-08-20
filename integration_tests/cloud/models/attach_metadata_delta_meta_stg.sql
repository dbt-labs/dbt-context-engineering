{{ config(materialized='view') }}

{#- Simulates a metadata-only edit: title changes for one document while its chunk text (and
    every other document's title) stays exactly the same. Same var-driven-CASE technique
    content_hash_delta_stg.sql uses for a source-text edit; here the edit lands on the metadata
    side instead, mirroring the duckdb fixture (attach_metadata_delta_meta_stg.sql).
    amd_edit_id unset (the default) is phase 1, the unedited baseline. -#}
select
    document_id,
    case when document_id = '{{ var("amd_edit_id", "none") }}'
         then title || ' (revised)'
         else title
    end as title,
    citation_url
from {{ ref('fixture_documents') }}

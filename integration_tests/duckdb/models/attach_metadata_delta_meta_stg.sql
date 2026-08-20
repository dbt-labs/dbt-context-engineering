{{ config(materialized='view') }}

{#- Simulates a metadata-only edit: title changes for one document while its chunk text (and
    every other document's title) stays exactly the same. Same var-driven-CASE technique
    content_hash_delta_stg.sql uses for a source-text edit; here the edit lands on the metadata
    side instead, which is the gap incremental_delta_predicate's content_hash_column argument has
    to catch for attach_metadata: a chunk's own text unchanged, but the metadata joined onto it
    changed. amd_edit_id unset (the default) is phase 1, the unedited baseline. -#}
select
    document_id,
    case when document_id = '{{ var("amd_edit_id", "none") }}'
         then title || ' (revised)'
         else title
    end as title,
    citation_url
from {{ ref('fixture_documents') }}

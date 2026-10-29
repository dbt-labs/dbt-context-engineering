{{ config(materialized='view') }}
{#- Two-phase metadata fixture (var amd_phase), mirrors chunk_delta_units' cd_phase pattern.
    Simulates a metadata-only edit: title changes for one document while chunk_docs' own
    chunk_text (and every other document's title) stays exactly the same. This is the case
    attach_metadata's content_hash has to catch: chunk_text unchanged, metadata changed. -#}
select
    document_id,
    case when document_id = '{{ var("amd_edit_id", "none") }}'
         then title || ' (revised)'
         else title
    end as title,
    citation_url
from {{ ref('fixture_documents') }}

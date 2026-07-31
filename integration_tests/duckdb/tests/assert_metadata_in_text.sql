-- in_text=True: chunk_text must start with a "title: <title>\ncitation_url: <url>\n---\n"
-- block built from that chunk's own metadata columns. Returns rows only on failure.
select 'missing_prefix' as issue, chunk_id
from {{ ref('ce_chunk_metadata_text') }}
where chunk_text not like (
    'title: ' || title || chr(10) || 'citation_url: ' || citation_url || chr(10) || '---' || chr(10) || '%'
)

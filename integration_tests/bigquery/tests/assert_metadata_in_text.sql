{#- ce_chunk_metadata_text_bq (in_text=True): every chunk_text must open with the
    "title: ...\ncitation_url: ...\n---\n" block built from the same row's metadata columns. -#}
{%- set str_t = dbt.type_string() -%}
select 'missing_prefix' as issue, chunk_id
from {{ ref('ce_chunk_metadata_text_bq') }}
where chunk_text not like (
    'title: ' || cast(title as {{ str_t }}) || chr(10)
    || 'citation_url: ' || cast(citation_url as {{ str_t }}) || chr(10)
    || '---' || chr(10) || '%'
)

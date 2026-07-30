{#- ce_chunk_metadata_cols_sf (in_text=False): title/citation_url must be present on every chunk,
    equal to the source document's values, and must NOT have leaked into chunk_text. -#}
{%- set str_t = dbt.type_string() -%}
with chunks as (select * from {{ ref('ce_chunk_metadata_cols_sf') }}),
docs as (select * from {{ ref('ce_fixture_documents') }})
select 'missing_metadata' as issue, chunk_id from chunks
where title is null or citation_url is null
union all
select 'wrong_metadata' as issue, c.chunk_id from chunks c
join docs d on cast(c.partition_key as {{ str_t }}) = cast(d.document_id as {{ str_t }})
where c.title <> d.title or c.citation_url <> d.citation_url
union all
select 'metadata_leaked_into_text' as issue, chunk_id from chunks
where chunk_text like '---%' or chunk_text like 'title:%'

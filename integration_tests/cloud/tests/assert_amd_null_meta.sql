{#- attach_metadata's null-metadata-value edge case (materialization-concerns.md's open questions
   list). doc_2's two metadata rows agree on null for every column; proves DISTINCT collapses them
   to one (no fan-out: chunk_id stays unique) and that null flows through as null, not dropped or
   substituted, with content_hash still well-defined. amd_null_meta_text additionally proves the
   in_text prefix block renders an empty line for a null value rather than a literal
   "None"/"null" string, and is still prepended at all when every value is null. Rows only on
   failure. -#}
with cols as (
    select * from {{ ref('amd_null_meta') }}
),
bad_null_passthrough as (
    select 'null_not_passed_through' as issue, chunk_id
    from cols
    where partition_key = 'doc_2'
      and (title is not null or citation_url is not null)
),
bad_hash as (
    select 'content_hash_null_for_null_metadata' as issue, chunk_id
    from cols
    where partition_key = 'doc_2' and content_hash is null
),
bad_baseline as (
    select 'baseline_row_wrong' as issue, chunk_id
    from cols
    where partition_key = 'doc_1'
      and (title <> 'Doc One Real Title'
           or citation_url <> 'https://notion.example.com/doc_1_real')
),
text_variant as (
    select * from {{ ref('amd_null_meta_text') }}
),
bad_null_in_text as (
    select 'null_rendered_wrong_in_text' as issue, chunk_id
    from text_variant
    where partition_key = 'doc_2'
      and chunk_text not like 'title: ' || chr(10) || 'citation_url: ' || chr(10) || '---' || chr(10) || '%'
),
bad_leaked_literal as (
    select 'null_literal_leaked_into_text' as issue, chunk_id
    from text_variant
    where partition_key = 'doc_2'
      and (chunk_text like '%None%' or chunk_text like '%null%')
),
bad_baseline_in_text as (
    select 'baseline_row_wrong_in_text' as issue, chunk_id
    from text_variant
    where partition_key = 'doc_1'
      and chunk_text not like 'title: Doc One Real Title' || chr(10)
          || 'citation_url: https://notion.example.com/doc_1_real' || chr(10) || '---' || chr(10) || '%'
)
select * from bad_null_passthrough
union all select * from bad_hash
union all select * from bad_baseline
union all select * from bad_null_in_text
union all select * from bad_leaked_literal
union all select * from bad_baseline_in_text

{{ config(materialized='table') }}

{#- Metadata edge-case fixture for attach_metadata, joined against chunk_docs' real partition
    keys (doc_1/doc_2/doc_3 from fixture_documents) rather than a hand-built chunks fixture, so no
    new cross-engine array literal is needed.

      doc_1   one row, real values. Contrast baseline.
      doc_2   TWO rows, both null. Proves DISTINCT collapses agreeing-null rows to one, the same
              way it collapses agreeing non-null rows; a duplicate is not itself a conflict.
      doc_3   no row at all here (left unmatched on purpose; the LEFT JOIN's ordinary no-match
              case, not the same code path as doc_2's explicit nulls, but the same output shape). -#}
select cast('doc_1' as {{ dbt.type_string() }}) as document_id,
       cast('Doc One Real Title' as {{ dbt.type_string() }}) as title,
       cast('https://notion.example.com/doc_1_real' as {{ dbt.type_string() }}) as citation_url
union all
select 'doc_2', cast(null as {{ dbt.type_string() }}), cast(null as {{ dbt.type_string() }})
union all
select 'doc_2', cast(null as {{ dbt.type_string() }}), cast(null as {{ dbt.type_string() }})

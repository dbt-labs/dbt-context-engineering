{#- Functional-dependency guard for attach_metadata: every metadata column must be constant
    per key in the source relation. If a key carries conflicting values, attach_metadata's
    DISTINCT collapse yields more than one row for it, the join fans out the chunks, and
    chunk_id uniqueness breaks. This test names the offending source key directly, so the failure
    points at the source rather than at a downstream uniqueness violation. -#}
{%- set str_t = dbt.type_string() -%}
select 'fixture_documents' as source, cast(document_id as {{ str_t }}) as key
from {{ ref('fixture_documents') }}
group by document_id
having count(distinct title) > 1 or count(distinct citation_url) > 1
union all
select 'fixture_calls' as source, cast(call_id as {{ str_t }}) as key
from {{ ref('fixture_calls') }}
group by call_id
having count(distinct customer) > 1
    or count(distinct participants) > 1
    or count(distinct recording_url) > 1

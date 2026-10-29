{#- Functional-dependency guard for attach_metadata: every metadata column must be constant
    per key in the source relation. If a key carries conflicting values, attach_metadata's
    DISTINCT collapse yields more than one row for it, the join fans out the chunks, and
    chunk_id uniqueness breaks. This test names the offending source key directly, so the failure
    points at the source rather than at a downstream uniqueness violation.

    Mirrors attach_metadata's own row-tuple DISTINCT collapse rather than a per-column
    count(distinct col): count(distinct col) silently ignores NULL, so a key with one row at
    col = 'x' and another at col = NULL would pass undetected under that form, even though it's
    exactly the conflict this guard exists to catch. A row-tuple DISTINCT has no such blind spot,
    (key, NULL) and (key, 'x') are two different rows under DISTINCT, the same semantics
    attach_metadata's real join relies on. -#}
{%- set str_t = dbt.type_string() -%}
select 'fixture_documents' as source, cast(document_id as {{ str_t }}) as key
from (select distinct document_id, title, citation_url from {{ ref('fixture_documents') }}) t
group by document_id
having count(*) > 1
union all
select 'fixture_calls' as source, cast(call_id as {{ str_t }}) as key
from (select distinct call_id, customer, participants, recording_url from {{ ref('fixture_calls') }}) t
group by call_id
having count(*) > 1

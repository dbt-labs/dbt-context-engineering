-- LIVE validation of split_sentences' Redshift path (PCRE lookaround sentinel + SUPER unnest):
-- no empty/null sentences survive, every seed document is represented, and each document's
-- sentence_index starts at 1. The 3 seed docs each contain 3 sentences. Fail rows only.
select 'empty_sentence' as issue, sentence_id
from {{ ref('rs_sentences') }}
where sentence_text is null or trim(sentence_text) = ''
union all
select 'missing_document' as issue, cast(d.id as varchar) as sentence_id
from {{ ref('rs_docs') }} d
left join (select distinct document_id from {{ ref('rs_sentences') }}) s
    on s.document_id = d.id
where s.document_id is null
union all
select 'index_not_1_based' as issue, cast(document_id as varchar) as sentence_id
from (
    select document_id, min(sentence_index) as min_ix
    from {{ ref('rs_sentences') }}
    group by document_id
)
where min_ix <> 1

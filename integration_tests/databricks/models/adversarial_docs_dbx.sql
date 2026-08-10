{{ config(materialized='table') }}
{#- Tricky sentence boundaries for the split_sentences cross-engine parity test (#7): a decimal
    ("3.2"), consecutive terminators ("!?"), and a leading terminator run ("..."). See
    assert_split_adversarial_dbx for the golden sentence set (identical on every engine by design). -#}
select 'a1' as document_id, 'Section 3.2 is ready. Ship it.' as document_text
union all select 'a2', 'Wait!? Really'
union all select 'a3', '...go now.'

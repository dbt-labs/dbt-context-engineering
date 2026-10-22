{{ config(materialized='table') }}
-- split_sentences -> redshift__split_sentences_core: PCRE lookaround zero-width sentinel ('p' flag)
-- + split_to_array + unnest a derived-table SUPER column with AT. ZERO AI cost.
{{ dbt_context_engineering.split_sentences(
    relation=ref('rs_docs'),
    id_column='id',
    text_column='txt'
) }}

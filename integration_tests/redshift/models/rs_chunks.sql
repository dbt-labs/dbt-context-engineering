{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='partition_key'
) }}
-- chunk -> array_agg (json_parse('['||listagg(chr-encoded)||']') SUPER) for source_rows,
-- string_agg (listagg within group) for chunk_text, plus the window arithmetic. ZERO AI cost.
-- Incremental on purpose: the delta path exercises redshift__row_value_not_in (correlated NOT EXISTS,
-- since Redshift has no row-constructor IN) — run twice to exercise it live. delete+insert + unique_key
-- partition_key are the strategy chunk() requires on Redshift (ADR-0029 whole-partition replacement).
{{ dbt_context_engineering.chunk(
    relation=ref('rs_sentences'),
    id_column='sentence_id',
    order_column='sentence_index',
    text_column='sentence_text',
    partition_column='document_id'
) }}

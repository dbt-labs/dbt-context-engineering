{{ config(materialized='table') }}
{#- Deterministic, no AI: ce_chunk on Databricks (array-sort + array_join). -#}
{{ dbt_context_engineering.ce_chunk(
    relation=ref('ce_fixture_utterances'),
    id_column='utterance_id', order_column='turn_index', text_column='utterance_text',
    partition_column='call_id', label_column='speaker', target_tokens=40
) }}

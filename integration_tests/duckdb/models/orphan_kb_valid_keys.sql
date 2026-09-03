{{ config(materialized='view') }}
{#- Exposes orphan_kb_source's CURRENT rows under the same synthesized key knowledge_base()
    computes internally (source_type || '::' || source_id), so schema.yml can point a
    relationships test at it. knowledge_base's own output has no separate "valid keys" model to
    reference; this one exists purely so the relationships test has a target. -#}
select 'item::' || item_id as source_key
from {{ ref('orphan_kb_source') }}

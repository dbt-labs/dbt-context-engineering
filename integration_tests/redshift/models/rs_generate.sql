{{ config(materialized='table') }}
-- generate (unstructured) -> ce_text(render_prompt(...), object('maxTokens', 256)); text() identity.
select
    id,
    {{ dbt_context_engineering.text(
         dbt_context_engineering.generate('txt', dbt_context_engineering.prompt('rs_summary', 'v1'))
    ) }} as summary
from {{ ref('rs_docs') }}

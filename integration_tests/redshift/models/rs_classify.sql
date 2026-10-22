{{ config(materialized='table') }}
-- classify -> augment_prompt (enum constraints) + redshift_output_instruction('label'); trim() the
-- bare label back. Best-effort (no structured output on Redshift Bedrock).
select
    id,
    {{ dbt_context_engineering.classify(
         'txt',
         dbt_context_engineering.prompt('rs_signal', 'v1'),
         dbt_context_engineering.schema_def('rs_signal', 'v1')
    ) }} as signal
from {{ ref('rs_docs') }}

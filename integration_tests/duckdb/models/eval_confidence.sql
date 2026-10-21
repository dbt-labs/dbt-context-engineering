{{ config(materialized='table') }}
{#- eval() with confidence_column: accuracy and count per confidence bucket, plus 'unscored' for a
    null confidence (the classify fallback). -#}
{{ dbt_context_engineering.eval(ref('eval_confidence_preds'), 'pred', 'expected', confidence_column='confidence') }}

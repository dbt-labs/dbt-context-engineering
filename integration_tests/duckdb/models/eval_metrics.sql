{{ config(materialized='table') }}

{#- eval over the golden set: accuracy + per-label precision/recall, computed with zero AI
    spend. Known values are asserted by assert_eval_metrics (accuracy = 6/8 = 0.75). -#}
{{ dbt_context_engineering.eval(ref('eval_predictions'), 'predicted_label', 'expected_label') }}

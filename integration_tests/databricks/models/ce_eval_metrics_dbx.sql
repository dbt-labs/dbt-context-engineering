{{ config(materialized='table') }}

{#- Phase 7 DETERMINISTIC validation (no AI): ce_eval over the synthetic golden seed, executed on
    the real warehouse. Known metrics (accuracy 6/8 = 0.75) asserted by assert_eval_metrics_dbx. -#}
{{ dbt_context_engineering.ce_eval(ref('ce_fixture_eval'), 'predicted_label', 'expected_label') }}

{{ config(materialized='table') }}

{#- Phase 7 DETERMINISTIC validation (no AI): eval over the synthetic golden seed, executed on
    the real warehouse. Known metrics (accuracy 6/8 = 0.75) asserted by assert_eval_metrics. -#}
{{ dbt_context_engineering.eval(ref('fixture_eval'), 'predicted_label', 'expected_label') }}

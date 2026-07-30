{{ config(materialized='table') }}

{#- Golden-set predictions fixture for Phase 7. Every row is clean: evidence is a verbatim
    substring of input_text, and predicted_label is in the EXAMPLE_signal_classify v3 enum — so
    the ce_grounded + ce_conforms_to_schema generic tests attached in schema.yml must PASS. The
    prediction/expected columns feed ce_eval (see ce_eval_metrics). -#}
select
    example_id,
    input_text,
    expected_label,
    predicted_label,
    evidence
from {{ ref('ce_fixture_eval') }}

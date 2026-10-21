{{ config(
    materialized='table',
    enabled=dbt_context_engineering.decide_available(),
    pre_hook="{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text', prompt=tojson(decide_test_questions()), output_tokens=0) }}",
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('decide', model_name='ai_decide', relation=ref('fixture_utterances'), input_column='utterance_text', prompt=tojson(decide_test_questions())) }}",
        "{{ dbt_context_engineering.complete_ai_run('decide', model_name='ai_decide') }}"
    ]
) }}

{#- LIVE validation of decide(): one choice, one noul and one score question per utterance.
    Enabled only where decide_available() is true (Databricks); other engines have no decision
    model, and the duckdb tier asserts the compile error they get instead. -#}
select
    utterance_id,
    {{ dbt_context_engineering.decide('utterance_text', decide_test_questions()) }} as d
from {{ ref('fixture_utterances') }}

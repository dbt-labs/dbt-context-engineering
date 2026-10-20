{{ config(
    materialized='table',
    meta={'ai_prompt': {'name': 'EXAMPLE_signal_classify', 'version': 'v3'}},
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('extract', model_name='prompted-test', relation=ref('fixture_utterances'), input_column='utterance_text', output_tokens=50) }}",
        "{{ dbt_context_engineering.complete_ai_run('extract', model_name='prompted-test') }}"
    ]
) }}

{#- Stand-in for a generate/classify/extract model. Its log_ai_run reads the prompt and schema from
    meta.ai_prompt and takes an explicit output allowance, so est_tokens must count all three per row
    on top of the input text, not the input text alone (ADR-0035). Asserted by assert_call_tokens.
    No AI call is made. -#}
select count(*) as processed from {{ ref('fixture_utterances') }}

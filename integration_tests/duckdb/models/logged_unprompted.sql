{{ config(
    materialized='table',
    enabled=var('warn_probe', false),
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('generate', model_name='unprompted-test', relation=ref('fixture_utterances'), input_column='utterance_text') }}",
        "{{ dbt_context_engineering.complete_ai_run('generate', model_name='unprompted-test') }}"
    ]
) }}

{#- A generate stand-in with no meta.ai_prompt and no prompt= on its log_ai_run. The hook must still
    log, and must emit its "logs a generate call with no prompt" warning (ADR-0035). Disabled unless
    var warn_probe is set, so a normal build carries no standing warning; CI builds it on purpose
    and checks the output for the warning. -#}
select count(*) as processed from {{ ref('fixture_utterances') }}

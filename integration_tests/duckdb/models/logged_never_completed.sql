{{ config(
    materialized='table',
    post_hook="{{ dbt_context_engineering.log_ai_run('never_completed', model_name='never-completed-test', relation=ref('fixture_utterances'), input_column='utterance_text') }}"
) }}

{#- Deliberately logs WITHOUT a paired complete_ai_run, standing in for a model that errors after
    its log_ai_run hook fires but before it would reach a completion hook. Its row stays
    completed=false. assert_never_completed_stays_false checks that every row for this
    function_name, from any invocation, stays completed=false. -#}
select count(*) as processed from {{ ref('fixture_utterances') }}

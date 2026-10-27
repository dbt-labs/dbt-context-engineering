{#- model_name passed to log_ai_run/complete_ai_run below names the AI FUNCTION on Snowflake/
    Databricks ('ai_classify' — those engines' classify wrapper doesn't take a model argument
    of its own) but the actual MODEL var on BigQuery (var('model_generate'), the cost lever
    AI.GENERATE dispatches to) — preserved as-is from the pre-merge sf/dbx/bq fixtures, not
    something this merge changes. -#}
{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text') }}",
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('classify', model_name=('ai_classify' if target.type != 'bigquery' else var('model_generate')), relation=ref('fixture_utterances'), input_column='utterance_text') }}",
        "{{ dbt_context_engineering.complete_ai_run('classify', model_name=('ai_classify' if target.type != 'bigquery' else var('model_generate'))) }}"
    ]
) }}
{#- The governed pattern: guard (pre) + AI classify + log (post), live on the target warehouse. -#}
select
    utterance_id,
    call_id,
    {{ dbt_context_engineering.classify(
        'utterance_text',
        dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        dbt_context_engineering.schema_def('EXAMPLE_signal_classify', 'v3')
    ) }} as signal
from {{ ref('fixture_utterances') }}

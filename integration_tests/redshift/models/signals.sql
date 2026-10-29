{#- model_name passed to log_ai_run/complete_ai_run below names the AI FUNCTION on Snowflake/
    Databricks ('ai_classify' — those engines' classify wrapper doesn't take a model argument
    of its own) but the actual MODEL var on BigQuery (var('model_generate'), the cost lever
    AI.GENERATE dispatches to) — preserved as-is from the pre-merge sf/dbx/bq fixtures, not
    something this merge changes. -#}
{{ config(
    materialized='table',
    meta={'ai_prompt': {'name': 'EXAMPLE_signal_classify', 'version': 'v3'}},
    pre_hook="{{ dbt_context_engineering.guard_batch(ref('fixture_utterances'), 'utterance_text') }}",
    post_hook=[
        "{{ dbt_context_engineering.log_ai_run('classify', model_name=('ai_classify' if target.type != 'bigquery' else var('model_generate')), relation=ref('fixture_utterances'), input_column='utterance_text') }}",
        "{{ dbt_context_engineering.complete_ai_run('classify', model_name=('ai_classify' if target.type != 'bigquery' else var('model_generate'))) }}"
    ]
) }}
{#- The governed pattern: guard (pre) + AI classify + log (post), live on the target warehouse. The
    prompt is named once, in meta.ai_prompt; the body and both hooks read it from there (ADR-0035). -#}
select
    utterance_id,
    call_id,
    {{ dbt_context_engineering.classify(
        'utterance_text',
        dbt_context_engineering.config_prompt(),
        dbt_context_engineering.config_schema()
    ) }} as signal
from {{ ref('fixture_utterances') }}

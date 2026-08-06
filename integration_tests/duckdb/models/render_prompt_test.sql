{{ config(materialized='table') }}

{#- Validates prompt resolution + render_prompt placeholder substitution end to end.
    The AI wrappers themselves need a warehouse with AI functions (deferred), but the prompt
    assembly is pure string SQL and runs anywhere. -#}
select
    utterance_id,
    utterance_text,
    {{ dbt_context_engineering.render_prompt(
        dbt_context_engineering.prompt('EXAMPLE_signal_classify', 'v3'),
        'utterance_text'
    ) }} as rendered_prompt
from {{ ref('fixture_utterances') }}

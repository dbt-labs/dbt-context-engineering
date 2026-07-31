{{ config(materialized='table') }}

{#- Validates ce_augment_prompt deterministically (compile-time string op, no AI): the rendered
    prompt must carry the schema's enum labels, still contain the original prompt, and still
    substitute the input column. This is the logic the BigQuery wrappers rely on to constrain the
    model when output_schema can't carry the enum. -#}
select
    utterance_id,
    utterance_text,
    {{ dbt_context_engineering.ce_render_prompt(
        dbt_context_engineering.ce_augment_prompt(
            dbt_context_engineering.ce_prompt('EXAMPLE_signal_classify', 'v3'),
            dbt_context_engineering.ce_schema('EXAMPLE_signal_classify', 'v3')),
        'utterance_text') }} as augmented_prompt
from {{ ref('ce_fixture_utterances') }}

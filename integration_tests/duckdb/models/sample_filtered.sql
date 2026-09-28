{{ config(materialized='table') }}

{#- dev_sample_filter's caller. The README lists it as a delivered cost-governance capability, so
    the QUALIFY clause it emits needs a model that runs it on every engine.

    No AI call here on purpose. What is under test is the clause itself: that it is syntactically
    accepted, that it caps the row count to exactly the requested number, and that leaving
    ai_sample_rows unset emits nothing and passes the full corpus through. Wrapping a real AI
    function would add spend without testing anything this does not already cover.

    assert_dev_sample_filter reads the same var and asserts the resulting row count. -#}
select utterance_id, utterance_text
from {{ ref('fixture_utterances') }}
{{ dbt_context_engineering.dev_sample_filter() }}

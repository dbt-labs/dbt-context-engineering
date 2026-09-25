{{ config(
    materialized='table',
    pre_hook="{{ dbt_context_engineering.guard_agg_batch(ref('fixture_utterances'), 'utterance_text', 'call_id') }}"
) }}

{#- guard_agg_batch's PASS path, the ai_agg counterpart to guard_pass. Under the default ceiling
    (max_agg_group_tokens=100000) the tiny fixture's per-call groups are far below it, so every
    build proves the guard allows a normal group. The RAISE path is exercised separately by
    rebuilding with --vars '{max_agg_group_tokens: 1}' (see ci.yml).

    Here as well as in the cloud project because the guard is pure SQL, a sum of estimate_tokens
    per group, so duckdb exercises it exactly as a warehouse does and neither path costs
    anything. The cloud ai_agg pre-hook runs the same macro against a real engine. -#}
select call_id, count(*) as utterances
from {{ ref('fixture_utterances') }}
group by call_id

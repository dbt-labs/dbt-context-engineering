{{ config(materialized='table') }}

{#- Validates decide_answer / decide_error's DEFAULT (JSON-string) read path deterministically.
    The seeded results use the Databricks ai_decide envelope, {response: {answers}, metadata,
    error_message}, which is what the default branch reads. d2 is a failed row: response null,
    error_message set. No AI call is made. -#}
with raw as (
    select 'd1' as id,
        '{"response": {"answers": {'
        || '"topic": {"type": "choice", "choice": "pipeline_failure", "confidence": 0.82, "probabilities": {"pipeline_failure": 0.86, "observability": 0.1, "other": 0.04}},'
        || '"urgent": {"type": "noul", "probability": 0.71},'
        || '"tone": {"type": "score", "score": 1.4, "confidence": 0.6, "legend": {"0": "calm", "1": "concerned", "2": "angry"}, "probabilities": {"0": 0.1, "1": 0.4, "2": 0.5}}'
        || '}}, "metadata": {"version": "1.0"}, "error_message": null}' as d
    union all
    select 'd2' as id,
        '{"response": null, "metadata": {"version": "1.0"}, "error_message": "state too long"}' as d
)
select
    id,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'choice') }}                                   as topic,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'confidence', dbt.type_float()) }}             as topic_confidence,
    {{ dbt_context_engineering.decide_answer('d', 'topic', 'probabilities.observability', dbt.type_float()) }} as p_observability,
    {{ dbt_context_engineering.decide_answer('d', 'urgent', 'probability', dbt.type_float()) }}           as urgent_probability,
    {{ dbt_context_engineering.decide_answer('d', 'tone', 'score', dbt.type_float()) }}                   as tone_score,
    {{ dbt_context_engineering.decide_error('d') }}                                                       as error
from raw

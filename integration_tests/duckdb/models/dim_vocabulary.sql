{{ config(materialized='table', meta={'ai_vocabulary': {'name': 'call_topics', 'version': 'v1'}}) }}
{{ dbt_context_engineering.vocabulary_rows() }}

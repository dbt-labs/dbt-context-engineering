{{ config(materialized='table') }}
{#- Review fixture: in a real project a user-owned table the package only reads. Utterance 4 is
    reviewed, so the pipeline must never send it to the model and must report the approved term. -#}
select 4 as utterance_id, 'observability' as approved_term, 'alex' as reviewer,
       cast('2026-10-02 09:00:00' as timestamp) as reviewed_at

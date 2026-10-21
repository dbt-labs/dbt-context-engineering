{{ config(materialized='table') }}

{#- Review fixture: in a real project this is a user-owned table the package only reads. Id 5 has
    two reviews and the later one must win; 7 was reviewed and never decided; 8 has a null
    approved_term and must be ignored. -#}
select 5 as utterance_id, 'pricing' as approved_term, 'alex' as reviewer, cast('2026-10-01 09:00:00' as timestamp) as reviewed_at
union all select 5, 'other',   'sam',  cast('2026-10-02 09:00:00' as timestamp)
union all select 7, 'pricing', 'alex', cast('2026-10-01 10:00:00' as timestamp)
union all select 8, null,      'sam',  cast('2026-10-01 11:00:00' as timestamp)

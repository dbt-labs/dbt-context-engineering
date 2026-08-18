{{ config(severity=var('embedding_canary_test_severity', 'warn')) }}

{#-
  assert_embedding_canary_matches_baseline: fails (subject to severity) when a live
  embedding_canary probe's cosine similarity to its blessed baseline, AT THE SAME
  (probe_id, embedding_fn_fingerprint, adapter), drops below embedding_canary_similarity_threshold.
  A fingerprint bump is an INTENDED function change, so it is excluded by construction: the old
  baseline row simply does not join anymore, it does not fail, it no longer applies. To re-bless
  after an intended change, run `dbt run-operation print_embedding_canary --target <adapter>` and
  copy the printed rows into seeds/embedding_canary_baseline.csv, then `dbt seed`.

  severity is 'warn' by default (a benign live wobble should not fail a scheduled production
  build) and 'error' in CI via embedding_canary_test_severity, so a PR cannot merge past real
  drift. adapter is part of the join because a baseline vector from one warehouse's model was
  never meant to be compared against another's.
-#}

{% set threshold = var('embedding_canary_similarity_threshold', 0.999) %}
{#- duckdb's stand-in is always the fixed 3-element literal in embedding_canary.sql; only
    Snowflake's real embedding model needs the configured dimension var. -#}
{% set dimension = 3 if target.type == 'duckdb' else var('embedding_canary_vector_dimension', none) %}

with compared as (

    select
        c.probe_id,
        c.adapter,
        c.embedding_fn_fingerprint,
        {{ dbt_context_engineering.canary_cosine_similarity('c.embedding', 'b.baseline_vector', dimension) }} as observed_similarity
    from {{ ref('embedding_canary') }} c
    join {{ ref('embedding_canary_baseline') }} b
        on  c.probe_id                 = b.probe_id
        and c.embedding_fn_fingerprint = b.embedding_fn_fingerprint
        and c.adapter                  = b.adapter

)

select * from compared where observed_similarity < {{ threshold }}

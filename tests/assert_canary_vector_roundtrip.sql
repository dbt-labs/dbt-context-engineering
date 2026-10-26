{#-
  The re-bless workflow is `dbt run-operation print_embedding_canary`, then paste the printed rows
  into seeds/embedding_canary_baseline.csv. That path depends on canary_vector_to_json producing
  a string canary_cosine_similarity's baseline side can parse back into the same vector. Nothing
  else exercises it: the comparison path reads the seed's string directly and never serializes.

  This closes the loop on the live vector. Serialize it with canary_vector_to_json, feed the
  result back in as the baseline argument, and require the similarity to clear the same
  threshold assert_embedding_canary_matches_baseline uses. A serializer that drops precision,
  reorders, or truncates fails here, which is the exact way a re-blessed baseline would fail
  later.

  The threshold is the configured one rather than an arbitrary epsilon, because the property that
  matters is operational: a pasted baseline must still match. In practice the round trip lands at
  1.0.

  Runs on every tier, so each engine's own canary_vector_to_json and canary_cosine_similarity
  implementation is exercised against a real vector from that engine. On duckdb the vector is the
  fixed stand-in, so this covers the serializer, not a provider.
-#}

{% set threshold = var('embedding_canary_similarity_threshold', 0.999) %}
{#- Matches assert_embedding_canary_matches_baseline: duckdb's stand-in is the fixed 3-element
    literal, and only Snowflake's VECTOR cast needs the configured dimension. -#}
{% set dimension = 3 if target.type == 'duckdb' else var('embedding_canary_vector_dimension', none) %}

with roundtripped as (

    select
        probe_id,
        adapter,
        {{ dbt_context_engineering.canary_cosine_similarity(
             'embedding',
             dbt_context_engineering.canary_vector_to_json('embedding'),
             dimension) }} as roundtrip_similarity
    from {{ ref('embedding_canary') }}

)

select * from roundtripped where roundtrip_similarity < {{ threshold }}

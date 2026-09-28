{{ config(materialized='table') }}

{#-
  canary_calibration: known-cosine fixtures for canary_cosine_similarity, not a copy of
  embedding_canary. embedding_canary compares near-identical vectors on every tier, a fixed
  stand-in against itself on duckdb and a fresh embedding against its own blessed baseline on the
  warehouses, so its similarity sits at or next to 1.0 and the comparison passes at any threshold.
  It exercises the join, parse and re-bless plumbing and proves nothing about the arithmetic. This
  model instead constructs vectors at KNOWN cosine similarities to [1.0, 2.0, 3.0], so a
  downstream test can assert both that canary_cosine_similarity is numerically correct and that
  the default threshold (ADR-0026, embedding_canary_similarity_threshold) sits where it should,
  on each engine's own implementation.

  Each vector is w = cos*v_hat + sin*u_hat, where v_hat is [1,2,3] normalized and u_hat is a unit
  vector orthogonal to v ([2,-1,0] normalized, chosen so v.u = 0). Because v_hat and u_hat are an
  orthonormal basis, w is unit-length by construction and cos(w, v) = cos exactly, which makes
  each row's expected_similarity a closed-form fact rather than an approximation. Do not
  hand-edit the vector literals below. They were generated from the target similarities, not the
  reverse.
-#}

select 'calib_9999' as probe_id, 0.9999 as expected_similarity,
    {{ dbt_context_engineering.canary_cosine_similarity(t_vec([0.2798833, 0.5281446, 0.8017035]), "'[1.0,2.0,3.0]'", 3) }} as observed_similarity
union all
select 'calib_999', 0.9990,
    {{ dbt_context_engineering.canary_cosine_similarity(t_vec([0.3069840, 0.5139930, 0.8009819]), "'[1.0,2.0,3.0]'", 3) }}
union all
select 'calib_99', 0.9900,
    {{ dbt_context_engineering.canary_cosine_similarity(t_vec([0.3907631, 0.4660900, 0.7937659]), "'[1.0,2.0,3.0]'", 3) }}
union all
select 'calib_95', 0.9500,
    {{ dbt_context_engineering.canary_cosine_similarity(t_vec([0.5331830, 0.3681540, 0.7616945]), "'[1.0,2.0,3.0]'", 3) }}

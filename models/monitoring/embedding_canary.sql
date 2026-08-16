{{ config(materialized='table', tags=['embedding_canary']) }}

{#-
  embedding_canary: runtime drift monitor (ADR-0026). Embeds a small fixed probe set every build
  and keeps the raw vector; assert_embedding_canary_matches_baseline compares it against a
  blessed baseline via cosine similarity (canary_cosine_similarity), so a provider-side change
  that reaches this warehouse weeks after merge turns into a red test instead of something a
  human has to already suspect. Complements, does not replace, embedding_logic_hash's CI-time
  golden-vector hash (ADR-0025), which catches package-code drift before merge and cannot see a
  live warehouse at all.

  Probe text is FROZEN. Do not edit any of the four probe_text values below -- that re-baselines
  on purpose (see the seed's re-bless workflow). Each probe exists to catch a different class of
  drift: pangram is the general-purpose baseline, short/long exercise length-dependent behavior,
  unicode exercises non-ASCII tokenization.

  duckdb has no embed() implementation (default__embed raises; matches every other AI call in
  this package, LIVE-VALIDATION DEFERRED per the README) and never will reach parity with the
  three real engines -- it has no AI functions. The duckdb branch below sources a fixed stand-in
  literal instead, same precedent as content_hash_delta's stand-in (ADR-0020). A green duckdb
  canary verifies the hash/baseline/re-bless PLUMBING only -- it proves nothing about provider
  drift, because there is no real provider behind the stand-in.

  Table, not incremental: every build reflects "now," not an accumulated history.
-#}

{% set is_duckdb = target.type == 'duckdb' %}
{% set stand_in_model = 'embedding-canary-standin' %}
{% set model_version = stand_in_model if is_duckdb else var('embedding_model') %}
{% set fingerprint = dbt_context_engineering.embedding_fn_fingerprint(model=(stand_in_model if is_duckdb else none)) %}

with probes as (

    select 'pangram' as probe_id, 'the quick brown fox jumps over the lazy dog' as probe_text
    union all
    select 'short', 'hi'
    union all
    select 'long', 'The history of computing spans many decades, beginning with mechanical calculators and evolving through vacuum tubes, transistors, and integrated circuits into the modern era of cloud computing and artificial intelligence. Each generation of technology builds on the last, compounding capability while shrinking cost and size.'
    union all
    select 'unicode', 'héllo wörld 🚀 ñ ü 日本語 áéíóú'

)

select
    probe_id,
    probe_text,
    '{{ model_version }}'                     as model_version,
    '{{ fingerprint }}'                       as embedding_fn_fingerprint,
    cast('{{ run_started_at }}' as timestamp) as observed_at,
    {% if is_duckdb -%}
    [1.0, 2.0, 3.0] as embedding
    {%- else -%}
    {{ dbt_context_engineering.embed('probe_text') }} as embedding
    {%- endif %},
    '{{ target.type }}'                       as adapter
from probes

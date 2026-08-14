{#-
  embedding_logic_hash() -> a content hash of the embedding-relevant source in this
  package. GENERATED, do not hand-edit. Regenerate with:
    python ci/verify_embedding_logic_hash.py --generate

  File set, derived by walking embed()'s call graph, not hand-listed. See
  ci/verify_embedding_logic_hash.py and ADR-0025:
    - macros/functions/embed.sql
    - macros/functions/require_prerequisites.sql

  Audit column only, never a fingerprint input, never gates reprocessing. CI
  recomputes this on every change and fails the build if it disagrees with what's
  checked in here, so a stale value is a blocked merge, not a silent gap.
-#}

{% macro embedding_logic_hash() -%}
    {{ return('d5f465efbd4dda4f2fbbac742ced40dcb22ad06c637560e9316d5b48a9f26a4d') }}
{%- endmacro %}

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
    {{ return('3672cbdde4ca279fd708a74ee8901bbebc103a202c67dd331cb8b7e82bed5159') }}
{%- endmacro %}

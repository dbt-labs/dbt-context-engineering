-- ADR-0029 verification fixture: confirms the downstream embed() no-op across a pure
-- chunk_fn_fingerprint bump, end to end, not just reasoned from determinism. Phase 1
-- (fp_probe_id_col unset, the default 'unit_id') is the baseline. Phase 2
-- (fp_probe_id_col='unit_id_alias', run WITHOUT --full-refresh right after phase 1) swaps
-- chunk()'s id_column to a column holding the exact same values under a different name, bumping
-- chunk_fn_fingerprint (id_column is hashed by name) without changing any actual output chunk()
-- produces. Every partition comes back dirty (partition_hash changes) and gets whole-partition
-- rebuilt, but chunk_id/chunk_text stay byte-identical, so the downstream content-hash delta
-- sees ZERO rows to re-embed. row_count=0 on phase 2 is the point of this fixture; row_count=2
-- (both chunks) on phase 1. See TESTING.md 4.9. The post-hook side effect is invisible to the
-- DAG, so depend on the logging model to run after it:
-- depends_on: {{ ref('chunk_fp_probe_embed') }}
{% set phase2 = var('fp_probe_id_col', 'unit_id') != 'unit_id' %}
{% set expected_row_count = 0 if phase2 else 2 %}
select 'wrong_row_count' as issue, row_count
from {{ ref('ai_run_log') }}
where invocation_id = '{{ invocation_id }}'
  and function_name = 'embed'
  and model_name = 'fp-probe-test'
  and event = 'started'
  and row_count <> {{ expected_row_count }}

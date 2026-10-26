{#-
  ADR-0025 makes embedding_logic_hash() an audit column, and embedding_canary emits it
  (models/monitoring/embedding_canary.sql). This asserts the value survives the trip to the
  warehouse: it is exactly the 64 lowercase hex characters the generator writes, and it equals
  what the macro returns on this run.

  The equality check is about the warehouse's column type, catching a value that came back
  truncated or re-cased. It is not an independent recomputation of the hash.
  ci/verify_embedding_logic_hash.py is what proves the value is correct, and it gates every
  merge.

  Fail rows only, with both values visible.
-#}

select
    probe_id,
    adapter,
    embedding_logic_hash               as stored_hash,
    '{{ dbt_context_engineering.embedding_logic_hash() }}' as expected_hash
from {{ ref('embedding_canary') }}
where embedding_logic_hash != '{{ dbt_context_engineering.embedding_logic_hash() }}'
   or length(embedding_logic_hash) != 64
   or lower(embedding_logic_hash) != embedding_logic_hash

-- LIVE groundedness of real ce_extract evidence on this warehouse: when the model returns a
-- non-empty evidence quote, it must actually appear (case/whitespace-normalized) in the source
-- utterance. A returned row is a HALLUCINATED quote. Behavioral — surfaces real model quality, not
-- just code bugs; empty evidence is not flagged. Fail rows only.
select utterance_id, evidence
from {{ ref('ce_extract_flat_sf') }}
where evidence is not null
  and length(trim(evidence)) > 0
  and not (
    {{ dbt_context_engineering.ce_contains(
        dbt_context_engineering.ce_norm_text('utterance_text', true, true),
        dbt_context_engineering.ce_norm_text('evidence',       true, true)) }}
  )

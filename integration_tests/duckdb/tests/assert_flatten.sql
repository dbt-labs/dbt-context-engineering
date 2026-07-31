-- ce_field must pull each schema field out of a JSON-string result and ce_text must pass the raw
-- text through. Returns rows only on failure.
with f as (
    select * from {{ ref('ce_flatten_test') }}
)
select id, signal, evidence
from f
where not (
    (id = 'e1' and signal = 'pain_point' and evidence = 'keeps breaking')
 or (id = 'e2' and signal = 'objection'  and evidence = 'pricing is higher')
)
   or raw_text is null
   or not contains(raw_text, signal)   -- ce_text returned the underlying JSON, which contains the field values

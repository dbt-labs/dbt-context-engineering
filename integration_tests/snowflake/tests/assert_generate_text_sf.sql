-- LIVE validation of text: the normalized plain-text output must be non-empty on this warehouse
-- (in particular BigQuery's STRUCT `.result` extraction). Fail rows only.
select utterance_id
from {{ ref('generate_text_sf') }}
where txt is null or length(trim(txt)) = 0

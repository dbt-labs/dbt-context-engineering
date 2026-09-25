-- Soft token cap: units are atomic, so a chunk may overshoot target by at most one unit.
-- target_tokens=40, and the largest single assembled utterance on the seed is about 22 tokens,
-- so no chunk's token_estimate should exceed 40 + 22 = 62. Fail rows only.
select chunk_id, token_estimate
from {{ ref('chunk_utterances') }}
where token_estimate > 62

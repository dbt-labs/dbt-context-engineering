-- augment_prompt must inject every enum label, preserve the original prompt, and keep the input
-- substitution. Returns rows only on failure.
select utterance_id
from {{ ref('augment_test') }}
where not contains(augmented_prompt, 'pain_point')        -- enum labels injected
   or not contains(augmented_prompt, 'buying_signal')
   or not contains(augmented_prompt, 'other')
   or not contains(augmented_prompt, 'Follow these value constraints')  -- the constraint block
   or not contains(augmented_prompt, 'Classify the sales-call segment')  -- original prompt preserved
   or not contains(augmented_prompt, utterance_text)      -- {{ input }} still substituted per row

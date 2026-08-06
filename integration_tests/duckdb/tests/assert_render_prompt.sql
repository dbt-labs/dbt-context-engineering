-- render_prompt must (a) keep the fixed preamble and (b) substitute each row's input text.
-- Returns rows only on failure.
select utterance_id
from {{ ref('render_prompt_test') }}
where not starts_with(rendered_prompt, 'Classify the sales-call segment')
   or not contains(rendered_prompt, utterance_text)
   or contains(rendered_prompt, '{% raw %}{{ input }}{% endraw %}')  -- placeholder must be gone

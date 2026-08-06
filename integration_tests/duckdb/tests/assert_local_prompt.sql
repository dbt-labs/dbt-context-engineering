-- Regression for prompt/schema resolution: a prompt AND schema defined in the CONSUMING project
-- (duckdb_tests, macros/local_prompts.sql) must resolve through prompt / schema — the
-- resolver looks in the flat namespace, not only this package. The marker text and the
-- alpha_label/beta_label enum exist ONLY in the project definition, so a package fallback can't make
-- this pass. Returns rows only on failure.
with r as (
    select
        utterance_id,
        utterance_text,
        {{ dbt_context_engineering.render_prompt(
             dbt_context_engineering.prompt('local_probe', 'v1'), 'utterance_text') }} as rendered
    from {{ ref('fixture_utterances') }}
)
select utterance_id
from r
where not contains(rendered, 'PROJECT-DEFINED-PROMPT')                 -- project prompt resolved
   or not contains(rendered, utterance_text)                           -- {{ input }} substituted
   or not contains('{{ dbt_context_engineering.schema_def("local_probe", "v1") | replace("'", "''") }}', 'alpha_label')  -- project schema resolved

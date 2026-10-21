{#-
  decide: ask a decision model typed questions about each row (issue #29). A decision model returns
  typed answers with a probability distribution instead of generated text, so a closed-set answer
  carries a confidence that classify's bare label cannot.

    select
      {{ dbt_context_engineering.decide_answer('d', 'topic', 'choice') }}      as topic,
      {{ dbt_context_engineering.decide_answer('d', 'topic', 'confidence', dbt.type_float()) }} as confidence
    from (
      select {{ dbt_context_engineering.decide('utterance_text', questions) }} as d
      from {{ ref('stg_utterances') }}
    ) as decided

  questions is a compile-time dict keyed by question id. Each question has `type` (noul / choice /
  score), `instructions`, and `criteria`: a label -> description mapping for choice (1 to the
  engine's cap), an ordered list of 2-10 levels for score, an optional {true, false} mapping for
  noul. Validated at compile time by validate_decide_questions. Define them in a project macro and
  call it from the body and the guard_batch / log_ai_run hooks, so all three share one definition.

  OUTPUT CONTRACT: decide returns the engine's raw result, one value per row. Read it with
  decide_answer / decide_error, which normalize the per-engine shape at read time. Normalizing
  inside decide would mean one engine call per extracted field, each one billed.

  ENGINES (decide_available is the single source of truth):
    - Databricks: ai_decide (Beta). Returns VARIANT {response: {answers}, metadata, error_message}.
    - Snowflake: Snowflake Decision via AI_COMPLETE, private preview. Written against the
      documented shape and disabled unless var decide_snowflake_preview is true.
      LIVE-VALIDATION DEFERRED.
    - BigQuery and others: no decision model. classify() is the supported route.
  LIVE-VALIDATION: Databricks.
-#}
{% macro decide(state_column, questions) -%}
    {{ dbt_context_engineering.require_ai_functions_enabled('decide') }}
    {{ dbt_context_engineering.require_safe_materialization('decide') }}
    {{ dbt_context_engineering.require_full_refresh_gate('decide') }}
    {%- do dbt_context_engineering.validate_decide_questions(questions, dbt_context_engineering.decide_choice_cap()) -%}
    {%- if not dbt_context_engineering.decide_available() -%}
        {#- execute-gated, same reasoning as default__classify: parse renders every model, and the
            return value is spliced into the caller's SELECT, so parse needs a placeholder. -#}
        {%- if execute -%}
            {{ exceptions.raise_compiler_error(dbt_context_engineering.decide_unsupported_message()) }}
        {%- endif -%}
        {{ return('null') }}
    {%- endif -%}
    {{ return(adapter.dispatch('decide', 'dbt_context_engineering')(state_column, questions)) }}
{%- endmacro %}


{#- decide_available() -> true where this package can run decide on the current target. The one
    place engine support is decided; decide() and anything built on it consult this. -#}
{% macro decide_available() -%}
    {%- if target.type == 'databricks' -%}
        {{ return(true) }}
    {%- elif target.type == 'snowflake' -%}
        {#- Compared as normalized text, not truthiness: a Jinja expression in dbt_project.yml
            renders to a string, and the string 'false' is truthy (see require_ai_functions_enabled). -#}
        {{ return((var('decide_snowflake_preview', false) | string | trim | lower) == 'true') }}
    {%- endif -%}
    {{ return(false) }}
{%- endmacro %}


{% macro decide_unsupported_message() -%}
    {%- set msg = "decide() is not supported on the '" ~ target.type ~ "' adapter: this platform "
        ~ "does not yet offer a decision model this package can call. Use classify() instead; it "
        ~ "labels from the same fixed set, without a confidence. Supported: databricks." -%}
    {%- if target.type == 'snowflake' -%}
        {%- set msg = msg ~ " Snowflake Decision (AI_COMPLETE, private preview) is written but "
            ~ "not yet validated; an account with preview access can opt in with var "
            ~ "decide_snowflake_preview: true." -%}
    {%- endif -%}
    {{ return(msg) }}
{%- endmacro %}


{#- decide_choice_cap() -> the most labels a choice question may carry on the current engine, from
    the engine's documented limit, overridable by var in case an engine raises it. none where
    decide is unavailable. -#}
{% macro decide_choice_cap() -%}
    {%- if target.type == 'databricks' -%}
        {{ return(var('decide_choice_cap_databricks', 255) | int) }}
    {%- elif target.type == 'snowflake' -%}
        {{ return(var('decide_choice_cap_snowflake', 32) | int) }}
    {%- endif -%}
    {{ return(none) }}
{%- endmacro %}


{#- validate_decide_questions(questions, cap) -> raises a compiler error naming the first problem.
    Execute-gated like the require_* checks: parse renders every model, so an unguarded raise here
    would break parsing of the whole project, not just the model with the bad question. -#}
{% macro validate_decide_questions(questions, cap=none) -%}
    {%- if not execute -%}{{ return(none) }}{%- endif -%}
    {%- if questions is not mapping or (questions | length) == 0 -%}
        {%- do exceptions.raise_compiler_error("decide: questions must be a non-empty dict keyed by question id.") -%}
    {%- endif -%}
    {%- for qid, q in questions.items() -%}
        {%- if not modules.re.match('^[A-Za-z_][A-Za-z0-9_]*$', qid | string) -%}
            {%- do exceptions.raise_compiler_error("decide: question id '" ~ qid ~ "' must be letters, digits and underscores, not starting with a digit, so decide_answer can address it.") -%}
        {%- endif -%}
        {%- if q is not mapping -%}
            {%- do exceptions.raise_compiler_error("decide: question '" ~ qid ~ "' must be a dict with type, instructions and criteria.") -%}
        {%- endif -%}
        {%- set extra = q.keys() | reject('in', ['type', 'instructions', 'criteria']) | list -%}
        {%- if extra -%}
            {%- do exceptions.raise_compiler_error("decide: question '" ~ qid ~ "' has unsupported field(s) " ~ extra | join(', ') ~ "; only type, instructions and criteria are allowed.") -%}
        {%- endif -%}
        {%- if q.get('type') not in ['noul', 'choice', 'score'] -%}
            {%- do exceptions.raise_compiler_error("decide: question '" ~ qid ~ "' type must be noul, choice or score, got '" ~ q.get('type') ~ "'.") -%}
        {%- endif -%}
        {%- if not q.get('instructions') -%}
            {%- do exceptions.raise_compiler_error("decide: question '" ~ qid ~ "' needs non-empty instructions.") -%}
        {%- endif -%}
        {%- set c = q.get('criteria') -%}
        {%- if q.type == 'choice' -%}
            {%- if c is not mapping or (c | length) == 0 -%}
                {%- do exceptions.raise_compiler_error("decide: choice question '" ~ qid ~ "' needs criteria as a non-empty label -> description dict.") -%}
            {%- endif -%}
            {%- if cap is not none and (c | length) > cap -%}
                {%- do exceptions.raise_compiler_error("decide: choice question '" ~ qid ~ "' has " ~ (c | length) ~ " labels; " ~ target.type ~ " accepts at most " ~ cap ~ " (var decide_choice_cap_" ~ target.type ~ "). Split it into a hierarchical vocabulary.") -%}
            {%- endif -%}
        {%- elif q.type == 'score' -%}
            {%- if c is mapping or c is string or c is not iterable or (c | length) < 2 or (c | length) > 10 -%}
                {%- do exceptions.raise_compiler_error("decide: score question '" ~ qid ~ "' needs criteria as a list of 2 to 10 levels, lowest first.") -%}
            {%- endif -%}
        {%- elif c is not none -%}
            {%- if c is not mapping or (c.keys() | reject('in', ['true', 'false']) | list) -%}
                {%- do exceptions.raise_compiler_error("decide: noul question '" ~ qid ~ "' criteria may only hold 'true' and 'false' descriptions.") -%}
            {%- endif -%}
        {%- endif -%}
    {%- endfor -%}
{%- endmacro %}


{% macro default__decide(state_column, questions) -%}
    {#- Unreachable through decide(), which checks decide_available first. Kept so a direct
        dispatch on an unsupported engine fails with the same message, not an opaque error. -#}
    {%- if execute -%}
        {{ exceptions.raise_compiler_error(dbt_context_engineering.decide_unsupported_message()) }}
    {%- endif -%}
    {{ return('null') }}
{%- endmacro %}


{% macro databricks__decide(state_column, questions) -%}
    {{ dbt_context_engineering.require_databricks_ai_runtime() }}
    {#- ai_decide requires questions as a constant STRING, the same definitions for every row. -#}
    ai_decide({{ state_column }}, {{ dbt_context_engineering.str_literal(tojson(questions)) }})
{%- endmacro %}


{#- Snowflake Decision through AI_COMPLETE, per Snowflake's announcement: the request is JSON with
    `state` and `questions`. LIVE-VALIDATION DEFERRED: our only call (2026-10-20) failed before
    reaching the model, "The model you requested is unavailable in your region". to_varchar makes
    the parse indifferent to whether AI_COMPLETE hands back text or an OBJECT for this model. -#}
{% macro snowflake__decide(state_column, questions) -%}
    parse_json(to_varchar(ai_complete(
        model => 'snowflake-decision',
        prompt => to_json(object_construct(
            'state', {{ state_column }},
            'questions', parse_json({{ dbt_context_engineering.str_literal(tojson(questions)) }})
        ))
    )))
{%- endmacro %}


{#-
  decide_answer(decision, question, field, as_type=none) -> one field of one question's answer from
  a decide() result, cast to as_type (default: the engine's string type).
    choice: choice, confidence, probabilities (JSON text), probabilities.<label>
    score:  score, confidence, legend, probabilities
    noul:   probability
  decide_error(decision) -> the engine's error text for a failed row, null on success.

  The default branch reads a JSON string in the Databricks envelope, which is what the duckdb tier
  seeds, so the read path is tested deterministically.
-#}
{% macro decide_answer(decision, question, field, as_type=none) -%}
    {%- set t = as_type if as_type is not none else dbt.type_string() -%}
    {{ return(adapter.dispatch('decide_answer', 'dbt_context_engineering')(decision, question, field, t)) }}
{%- endmacro %}

{% macro default__decide_answer(decision, question, field, as_type) -%}
    cast(json_extract_string({{ decision }}, '$.response.answers.{{ question }}.{{ field }}') as {{ as_type }})
{%- endmacro %}

{#- VARIANT path access; `decision` must be a column reference, not an expression. -#}
{% macro databricks__decide_answer(decision, question, field, as_type) -%}
    cast({{ decision }}:response.answers.{{ question }}.{{ field }} as {{ as_type }})
{%- endmacro %}


{#- Snowflake Decision's documented result is an `answers` object with no envelope, and its noul
    answer names the probability `noul` where Databricks says `probability`. LIVE-VALIDATION
    DEFERRED. -#}
{% macro snowflake__decide_answer(decision, question, field, as_type) -%}
    {%- set f = 'noul' if field == 'probability' else field -%}
    cast(({{ decision }}):answers.{{ question }}.{{ f }} as {{ as_type }})
{%- endmacro %}


{% macro decide_error(decision) -%}
    {{ return(adapter.dispatch('decide_error', 'dbt_context_engineering')(decision)) }}
{%- endmacro %}

{% macro default__decide_error(decision) -%}
    json_extract_string({{ decision }}, '$.error_message')
{%- endmacro %}

{% macro databricks__decide_error(decision) -%}
    cast({{ decision }}:error_message as string)
{%- endmacro %}

{#- Snowflake surfaces a failed AI_COMPLETE call as a query error, not an in-band field, so there
    is no per-row error to read. -#}
{% macro snowflake__decide_error(decision) -%}
    cast(null as varchar)
{%- endmacro %}


{#-
  decide_model(decision) -> what the engine reports about the model that answered, for the
  vocabulary pipeline's decision_model column. Neither native path exposes a versioned model id:
  Databricks reports only the ai_decide function version (metadata.version), Snowflake only the
  model name.
-#}
{% macro decide_model(decision) -%}
    {{ return(adapter.dispatch('decide_model', 'dbt_context_engineering')(decision)) }}
{%- endmacro %}

{% macro default__decide_model(decision) -%}
    ('ai_decide/' || json_extract_string({{ decision }}, '$.metadata.version'))
{%- endmacro %}

{% macro databricks__decide_model(decision) -%}
    ('ai_decide/' || cast({{ decision }}:metadata.version as string))
{%- endmacro %}

{% macro snowflake__decide_model(decision) -%}
    cast('snowflake-decision' as varchar)
{%- endmacro %}

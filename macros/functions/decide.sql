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
  call it from the body and the guard_batch / log_ai_run hooks, so all three share one definition;
  size them in the hooks with prompt=decide_questions_json(questions).

  OUTPUT CONTRACT: decide returns the engine's raw result, one value per row. Read it with
  decide_answer / decide_error, which normalize the per-engine shape at read time. Normalizing
  inside decide would mean one engine call per extracted field, each one billed.

  ENGINES (decide_available is the single source of truth):
    - Databricks: ai_decide (Beta). Returns VARIANT {response: {answers}, metadata, error_message}.
    - Snowflake: Snowflake Decision via AI_COMPLETE, private preview. Off unless var
      decide_snowflake_preview is true; the account must be enrolled and have
      CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION'. var decide_snowflake_model picks
      snowflake-decision-fast (default, Snowflake's recommendation) or snowflake-decision.
      Returns OBJECT {value: {answers}, error}.
    - BigQuery and others: no decision model. classify() is the supported route.
  LIVE-VALIDATION: Databricks, Snowflake (both models).
-#}
{% macro decide(state_column, questions) -%}
    {{ dbt_context_engineering.require_ai_functions_enabled('decide') }}
    {{ dbt_context_engineering.require_safe_materialization('decide') }}
    {{ dbt_context_engineering.require_full_refresh_gate('decide') }}
    {%- do dbt_context_engineering.validate_decide_questions(questions, dbt_context_engineering.decide_limits()) -%}
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
        {%- set msg = msg ~ " Snowflake Decision (AI_COMPLETE) is in private preview: an enrolled "
            ~ "account with CORTEX_ENABLED_CROSS_REGION = 'ANY_REGION' can opt in with var "
            ~ "decide_snowflake_preview: true." -%}
    {%- endif -%}
    {{ return(msg) }}
{%- endmacro %}


{#- decide_snowflake_model() -> the Snowflake Decision model AI_COMPLETE calls, from var
    decide_snowflake_model. Raises on any other value, since its limits would be unknown. -#}
{% macro decide_snowflake_model() -%}
    {%- set m = var('decide_snowflake_model', 'snowflake-decision-fast') | string | trim | lower -%}
    {%- if m not in ['snowflake-decision', 'snowflake-decision-fast'] and execute -%}
        {{ exceptions.raise_compiler_error("decide: var decide_snowflake_model must be 'snowflake-decision' or 'snowflake-decision-fast', got '" ~ m ~ "'.") }}
    {%- endif -%}
    {{ return(m) }}
{%- endmacro %}


{#- decide_limits() -> the current engine's documented request limits, as a dict for
    validate_decide_questions: choice_min / choice_max labels per choice question, max_questions,
    max_options (choice labels + 2 per noul + levels per score, summed over the request) and
    max_id_length. A limit the engine does not document is absent, not guessed. The choice caps
    are vars in case an engine raises them. Empty where decide is unavailable. -#}
{% macro decide_limits() -%}
    {%- if target.type == 'databricks' -%}
        {{ return({'choice_min': 1, 'choice_max': var('decide_choice_cap_databricks', 255) | int}) }}
    {%- elif target.type == 'snowflake' -%}
        {%- if dbt_context_engineering.decide_snowflake_model() == 'snowflake-decision-fast' -%}
            {{ return({'choice_max': var('decide_choice_cap_snowflake_fast', 16) | int}) }}
        {%- endif -%}
        {{ return({'choice_min': 2, 'choice_max': var('decide_choice_cap_snowflake', 32) | int,
                   'max_questions': 32, 'max_options': 256, 'max_id_length': 64}) }}
    {%- endif -%}
    {{ return({}) }}
{%- endmacro %}


{#- validate_decide_questions(questions, limits) -> raises a compiler error naming the first problem.
    limits is decide_limits()' dict; any key may be absent. Execute-gated like the require_*
    checks: parse renders every model, so an unguarded raise here would break parsing of the whole
    project, not just the model with the bad question. -#}
{% macro validate_decide_questions(questions, limits=none) -%}
    {%- if not execute -%}{{ return(none) }}{%- endif -%}
    {%- set limits = limits or {} -%}
    {%- if questions is not mapping or (questions | length) == 0 -%}
        {%- do exceptions.raise_compiler_error("decide: questions must be a non-empty dict keyed by question id.") -%}
    {%- endif -%}
    {%- if limits.get('max_questions') is not none and (questions | length) > limits['max_questions'] -%}
        {%- do exceptions.raise_compiler_error("decide: " ~ (questions | length) ~ " questions; " ~ target.type ~ " accepts at most " ~ limits['max_questions'] ~ " per call. Split them across decide() calls.") -%}
    {%- endif -%}
    {%- set ns_opts = namespace(total=0) -%}
    {%- for qid, q in questions.items() -%}
        {%- if not modules.re.match('^[A-Za-z_][A-Za-z0-9_]*$', qid | string) -%}
            {%- do exceptions.raise_compiler_error("decide: question id '" ~ qid ~ "' must be letters, digits and underscores, not starting with a digit, so decide_answer can address it.") -%}
        {%- endif -%}
        {%- if limits.get('max_id_length') is not none and (qid | string | length) > limits['max_id_length'] -%}
            {%- do exceptions.raise_compiler_error("decide: question id '" ~ qid ~ "' is " ~ (qid | string | length) ~ " characters; " ~ target.type ~ " accepts at most " ~ limits['max_id_length'] ~ ".") -%}
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
            {%- for label, desc in c.items() -%}
                {%- if label is not string or (label | trim) == '' or desc is not string or (desc | trim) == '' -%}
                    {%- do exceptions.raise_compiler_error("decide: choice question '" ~ qid ~ "' needs every label and description to be a non-empty string.") -%}
                {%- endif -%}
            {%- endfor -%}
            {%- if limits.get('choice_max') is not none and (c | length) > limits['choice_max'] -%}
                {%- do exceptions.raise_compiler_error("decide: choice question '" ~ qid ~ "' has " ~ (c | length) ~ " labels; " ~ target.type ~ " accepts at most " ~ limits['choice_max'] ~ " (var decide_choice_cap_" ~ target.type ~ "). Split it into a hierarchical vocabulary.") -%}
            {%- endif -%}
            {%- if limits.get('choice_min') is not none and (c | length) < limits['choice_min'] -%}
                {%- do exceptions.raise_compiler_error("decide: choice question '" ~ qid ~ "' has " ~ (c | length) ~ " label(s); " ~ target.type ~ " requires at least " ~ limits['choice_min'] ~ ". Ask a noul question for a single yes / no label.") -%}
            {%- endif -%}
            {%- set ns_opts.total = ns_opts.total + (c | length) -%}
        {%- elif q.type == 'score' -%}
            {%- if c is mapping or c is string or c is not iterable or (c | length) < 2 or (c | length) > 10 -%}
                {%- do exceptions.raise_compiler_error("decide: score question '" ~ qid ~ "' needs criteria as a list of 2 to 10 levels, lowest first.") -%}
            {%- endif -%}
            {%- set ns = namespace(seen=[]) -%}
            {%- for level in c -%}
                {%- if level is not string or (level | trim) == '' -%}
                    {%- do exceptions.raise_compiler_error("decide: score question '" ~ qid ~ "' needs every level to be a non-empty string.") -%}
                {%- endif -%}
                {%- if level in ns.seen -%}
                    {%- do exceptions.raise_compiler_error("decide: score question '" ~ qid ~ "' repeats the level '" ~ level ~ "'.") -%}
                {%- endif -%}
                {%- set ns.seen = ns.seen + [level] -%}
            {%- endfor -%}
            {%- set ns_opts.total = ns_opts.total + (c | length) -%}
        {%- elif c is not none -%}
            {%- if c is not mapping or (c.keys() | reject('in', ['true', 'false']) | list) -%}
                {%- do exceptions.raise_compiler_error("decide: noul question '" ~ qid ~ "' criteria may only hold 'true' and 'false' descriptions.") -%}
            {%- endif -%}
            {%- for desc in c.values() -%}
                {%- if desc is not string or (desc | trim) == '' -%}
                    {%- do exceptions.raise_compiler_error("decide: noul question '" ~ qid ~ "' needs its true / false descriptions to be non-empty strings.") -%}
                {%- endif -%}
            {%- endfor -%}
        {%- endif -%}
        {%- if q.type == 'noul' -%}{%- set ns_opts.total = ns_opts.total + 2 -%}{%- endif -%}
    {%- endfor -%}
    {%- if limits.get('max_options') is not none and ns_opts.total > limits['max_options'] -%}
        {%- do exceptions.raise_compiler_error("decide: the questions carry " ~ ns_opts.total ~ " options in all (choice labels, 2 per noul, levels per score); " ~ target.type ~ " accepts at most " ~ limits['max_options'] ~ " per call. Split them across decide() calls.") -%}
    {%- endif -%}
{%- endmacro %}


{#-
  decide_questions_json(questions) -> the questions as JSON text, in declared order: question ids
  as given, each question's fields as type, instructions, criteria, and choice labels as given.
  Built by hand because dbt Fusion's tojson sorts dict keys at every level while dbt Core keeps
  insertion order, so tojson(questions) sends a different request on each engine. Scalars and
  lists go through tojson, whose escaping and separators both engines share. Use it wherever the
  questions are sent or sized: decide() itself, and log_ai_run(..., prompt=) for decide.
-#}
{% macro decide_questions_json(questions) -%}
    {%- set ns = namespace(entries=[]) -%}
    {%- for qid, q in questions.items() -%}
        {%- set parts = ['"type": ' ~ tojson(q['type']), '"instructions": ' ~ tojson(q['instructions'])] -%}
        {%- set c = q.get('criteria') -%}
        {%- if c is mapping -%}
            {%- set kv = [] -%}
            {%- for k, v in c.items() -%}{%- do kv.append(tojson(k | string) ~ ': ' ~ tojson(v)) -%}{%- endfor -%}
            {%- do parts.append('"criteria": {' ~ (kv | join(', ')) ~ '}') -%}
        {%- elif c is not none -%}
            {%- do parts.append('"criteria": ' ~ tojson(c | list)) -%}
        {%- endif -%}
        {%- set ns.entries = ns.entries + [tojson(qid | string) ~ ': {' ~ (parts | join(', ')) ~ '}'] -%}
    {%- endfor -%}
    {{ return('{' ~ (ns.entries | join(', ')) ~ '}') }}
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
    ai_decide({{ state_column }}, {{ dbt_context_engineering.str_literal(dbt_context_engineering.decide_questions_json(questions)) }})
{%- endmacro %}


{#- Snowflake Decision through AI_COMPLETE: the request is JSON with `state` and `questions`. The
    request is assembled as text rather than with object_construct / parse_json, because a
    Snowflake OBJECT does not keep key order and the questions must go out in declared order
    (decide_questions_json); only the row's state is JSON-encoded by Snowflake.
    return_error_details => true, because without it a failed row is a bare NULL, indistinguishable
    from a row with no answer; with it the result is an OBJECT {value: {answers}, error}, which
    to_varchar rejects, hence to_variant. The model name is stored in the result, since
    Snowflake's own result does not name one. -#}
{% macro snowflake__decide(state_column, questions) -%}
    {%- set model = dbt_context_engineering.decide_snowflake_model() -%}
    object_insert(to_object(to_variant(ai_complete(
        model => {{ dbt_context_engineering.str_literal(model) }},
        prompt => '{"state": ' || to_json(to_variant({{ state_column }})) || ', "questions": '
            || {{ dbt_context_engineering.str_literal(dbt_context_engineering.decide_questions_json(questions)) }} || '}',
        return_error_details => true
    ))), 'model', {{ dbt_context_engineering.str_literal(model) }})
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


{#- snowflake__decide wraps the answers in `value` (return_error_details), and Snowflake's noul
    answer names the probability `noul` where Databricks says `probability`. -#}
{% macro snowflake__decide_answer(decision, question, field, as_type) -%}
    {%- set f = 'noul' if field == 'probability' else field -%}
    cast(({{ decision }}):value.answers.{{ question }}.{{ f }} as {{ as_type }})
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

{% macro snowflake__decide_error(decision) -%}
    cast(({{ decision }}):error as varchar)
{%- endmacro %}


{#-
  decide_model(decision) -> what the engine reports about the model that answered, for the
  vocabulary pipeline's decision_model column. Neither native path exposes a versioned model id:
  Databricks reports only the ai_decide function version (metadata.version); on Snowflake it is the
  model name snowflake__decide stored with the row.
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
    cast(({{ decision }}):model as varchar)
{%- endmacro %}

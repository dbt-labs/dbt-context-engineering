{#-
  Fixed-vocabulary classification (issue #29). A versioned, governed vocabulary goes in; each row
  comes out with a term, a confidence and a status. Human-approved terms always win.

  A model names its vocabulary once, in config(meta={'ai_vocabulary': {'name': ..., 'version': ...}}),
  the meta.ai_prompt pattern (ADR-0035). Every macro below takes name= / version= as optional
  overrides and otherwise reads that entry, and guard_batch / log_ai_run size the call from it with
  no prompt arguments (resolve_call_prompt).

  A vocabulary version is a macro `vocabulary__<name>__<version>()` in the calling project,
  resolved the way prompt() resolves prompts (ADR-0001, ADR-0032). It returns:

    {
      'instructions': 'What is this utterance mainly about?',
      'terms': [
        {'label': 'pipeline_reliability',            -- identifier-safe code, unique
         'definition': 'Pipelines failing or late',  -- required
         'scope_note': 'Not monitoring gaps',        -- optional boundary guidance
         'status': 'active',                         -- active (default) / deprecated
         'valid_from': '2026-10-01', 'valid_to': none,
         'synonyms': ['broken load']},
        ...
      ]
    }

  Only active terms are offered to the model. The same vocabulary renders both the decision-model
  choice criteria and the classify() schema enum, so the two paths cannot drift apart.

  The pipeline is two models, so the billed AI call is stored once and read many times:
    1. vocabulary_decide(): incremental, one AI call per row in the batch, raw result stored.
    2. vocabulary_labels(): table, reads the result, ranks the runner-up, routes by confidence,
       joins human reviews.
  Where decide_available() is false, the method follows var('decide_fallback'): 'error' (default)
  stops with a message naming the fallback, 'classify' labels with classify() and marks every row
  'unscored'.
-#}
{#- vocabulary_ref(name, version) -> [name, version]: the arguments when passed, otherwise the
    model's meta.ai_vocabulary, the meta.ai_prompt pattern (ADR-0035). At execute time a missing
    entry raises. During parse node config is not resolved, so it returns none and vocabulary()
    hands back a placeholder. -#}
{% macro vocabulary_ref(name=none, version=none) -%}
    {%- if name is not none and version is not none -%}{{ return([name, version]) }}{%- endif -%}
    {%- set entry = dbt_context_engineering.ai_meta_entry('ai_vocabulary') -%}
    {%- if entry is not none and entry.get('name') and entry.get('version') -%}
        {{ return([name or entry['name'], version or entry['version']]) }}
    {%- endif -%}
    {%- if execute -%}
        {{ exceptions.raise_compiler_error(
            "vocabulary: no vocabulary named. Set config(meta={'ai_vocabulary': {'name': '<vocabulary>', "
            ~ "'version': '<v>'}}) on the model, or pass name= and version=.") }}
    {%- endif -%}
    {{ return([none, none]) }}
{%- endmacro %}


{% macro vocabulary(name=none, version=none) -%}
    {%- set ref_ = dbt_context_engineering.vocabulary_ref(name, version) -%}
    {%- if ref_[0] is none -%}
        {#- parse-time placeholder: one active term, so every rendering below stays valid -#}
        {{ return({'instructions': 'placeholder', 'terms': [{'label': 'placeholder', 'definition': 'placeholder'}]}) }}
    {%- endif -%}
    {%- set fq = 'vocabulary__' ~ ref_[0] ~ '__' ~ ref_[1] -%}
    {%- set macro = context.get(fq) if context is defined else none -%}
    {%- if macro is none -%}
        {{ exceptions.raise_compiler_error(
            "vocabulary: vocabulary '" ~ ref_[0] ~ "' version '" ~ ref_[1] ~ "' not found. "
            ~ "Define a macro " ~ fq ~ "() on a macro path in your project.") }}
    {%- endif -%}
    {%- set v = macro() -%}
    {%- do dbt_context_engineering.validate_vocabulary(v, fq) -%}
    {{ return(v) }}
{%- endmacro %}


{#- Execute-gated like validate_decide_questions: parse renders every model, so an unguarded raise
    would break parsing of the whole project, not just the models using this vocabulary. -#}
{% macro validate_vocabulary(v, fq) -%}
    {%- if not execute -%}{{ return(none) }}{%- endif -%}
    {%- if v is not mapping or not v.get('instructions') -%}
        {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": must return a dict with non-empty instructions and terms.") }}
    {%- endif -%}
    {%- set terms = v.get('terms') -%}
    {%- if terms is mapping or terms is string or terms is not iterable or (terms | length) == 0 -%}
        {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": terms must be a non-empty list.") }}
    {%- endif -%}
    {%- set ns = namespace(seen=[], active=0) -%}
    {%- for t in terms -%}
        {%- set label = t.get('label') | string -%}
        {%- if not modules.re.match('^[a-z][a-z0-9_]*$', label) -%}
            {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": label '" ~ label ~ "' must be lowercase letters, digits and underscores, starting with a letter.") }}
        {%- endif -%}
        {%- if label in ns.seen -%}
            {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": label '" ~ label ~ "' appears more than once.") }}
        {%- endif -%}
        {%- set ns.seen = ns.seen + [label] -%}
        {%- if not t.get('definition') -%}
            {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": term '" ~ label ~ "' needs a definition.") }}
        {%- endif -%}
        {%- if t.get('status', 'active') not in ['active', 'deprecated'] -%}
            {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": term '" ~ label ~ "' status must be active or deprecated.") }}
        {%- endif -%}
        {%- if t.get('status', 'active') == 'active' -%}{%- set ns.active = ns.active + 1 -%}{%- endif -%}
    {%- endfor -%}
    {%- if ns.active == 0 -%}
        {{ exceptions.raise_compiler_error("vocabulary " ~ fq ~ ": has no active terms.") }}
    {%- endif -%}
{%- endmacro %}


{#- The active terms of a vocabulary, in declared order. -#}
{% macro vocabulary_active_terms(name=none, version=none) -%}
    {%- set ns = namespace(out=[]) -%}
    {%- for t in dbt_context_engineering.vocabulary(name, version).terms -%}
        {%- if t.get('status', 'active') == 'active' -%}{%- set ns.out = ns.out + [t] -%}{%- endif -%}
    {%- endfor -%}
    {{ return(ns.out) }}
{%- endmacro %}

{% macro vocabulary_labels_list(name=none, version=none) -%}
    {{ return(dbt_context_engineering.vocabulary_active_terms(name, version) | map(attribute='label') | list) }}
{%- endmacro %}


{#- One active term's description as the model sees it: definition, scope note, synonyms. -#}
{% macro vocabulary_term_text(t) -%}
    {%- set parts = [t.definition] -%}
    {%- if t.get('scope_note') -%}{%- do parts.append('Scope: ' ~ t.scope_note) -%}{%- endif -%}
    {%- if t.get('synonyms') -%}{%- do parts.append('Also called: ' ~ (t.synonyms | join(', '))) -%}{%- endif -%}
    {{ return(parts | join(' ')) }}
{%- endmacro %}


{#- vocabulary_question(name, version) -> the decide() question set: one choice question, `term`,
    whose criteria are the active terms and their descriptions. -#}
{% macro vocabulary_question(name=none, version=none) -%}
    {%- set v = dbt_context_engineering.vocabulary(name, version) -%}
    {%- set criteria = {} -%}
    {%- for t in dbt_context_engineering.vocabulary_active_terms(name, version) -%}
        {%- do criteria.update({t.label: dbt_context_engineering.vocabulary_term_text(t)}) -%}
    {%- endfor -%}
    {{ return({'term': {'type': 'choice', 'instructions': v.instructions, 'criteria': criteria}}) }}
{%- endmacro %}


{#- vocabulary_schema / vocabulary_prompt -> the classify() fallback's output schema (enum of
    active labels) and prompt (instructions plus every term's description). -#}
{% macro vocabulary_schema(name=none, version=none) -%}
    {{ return(tojson({'type': 'object',
                      'properties': {'term': {'type': 'string', 'enum': dbt_context_engineering.vocabulary_labels_list(name, version)}},
                      'required': ['term']})) }}
{%- endmacro %}

{% macro vocabulary_prompt(name=none, version=none) -%}
    {%- set v = dbt_context_engineering.vocabulary(name, version) -%}
    {%- set lines = [v.instructions, 'Choose exactly one term:'] -%}
    {%- for t in dbt_context_engineering.vocabulary_active_terms(name, version) -%}
        {%- do lines.append('- ' ~ t.label ~ ': ' ~ dbt_context_engineering.vocabulary_term_text(t)) -%}
    {%- endfor -%}
    {%- set placeholder -%}{%- raw -%}{{ input }}{%- endraw -%}{%- endset -%}
    {%- do lines.append('Text: ' ~ placeholder) -%}
    {{ return(lines | join('\n')) }}
{%- endmacro %}


{#- vocabulary_method(fallback=none) -> 'decide' where decide_available(), else the fallback.
    'error' (the default) raises at execute time with a message naming decide_fallback: classify. -#}
{% macro vocabulary_method(fallback=none) -%}
    {%- if dbt_context_engineering.decide_available() -%}{{ return('decide') }}{%- endif -%}
    {%- set fb = (fallback if fallback is not none else var('decide_fallback', 'error')) | string | trim | lower -%}
    {%- if fb == 'classify' -%}{{ return('classify') }}{%- endif -%}
    {%- if execute -%}
        {{ exceptions.raise_compiler_error(
            "vocabulary: the '" ~ target.type ~ "' platform does not yet support decision models. "
            ~ "Set var decide_fallback: classify, the correct route here: it labels with classify() "
            ~ "from the same vocabulary and marks rows 'unscored', since classify returns no "
            ~ "confidence." ~ (" Got decide_fallback: '" ~ fb ~ "'." if fb != 'error' else "")) }}
    {%- endif -%}
    {{ return('classify') }}
{%- endmacro %}


{#- vocabulary_key(name, version, method) -> the stored version identity of a decided row. A change
    to the vocabulary version or the method reprocesses every row (version_guard). -#}
{% macro vocabulary_key(name=none, version=none, method=none) -%}
    {%- set ref_ = dbt_context_engineering.vocabulary_ref(name, version) -%}
    {{ return((ref_[0] or 'placeholder') ~ '@' ~ (ref_[1] or 'v0') ~ '/' ~ (method or dbt_context_engineering.vocabulary_method())) }}
{%- endmacro %}


{#- The text and schema each row's AI call carries, for guard_batch / log_ai_run's prompt= and
    output_schema=, so the cost estimate counts them (ADR-0035). -#}
{% macro vocabulary_sent_prompt(name=none, version=none) -%}
    {%- if dbt_context_engineering.vocabulary_method() == 'decide' -%}
        {{ return(dbt_context_engineering.decide_questions_json(dbt_context_engineering.vocabulary_question(name, version))) }}
    {%- endif -%}
    {{ return(dbt_context_engineering.vocabulary_prompt(name, version)) }}
{%- endmacro %}

{% macro vocabulary_sent_schema(name=none, version=none) -%}
    {%- if dbt_context_engineering.vocabulary_method() == 'decide' -%}{{ return(none) }}{%- endif -%}
    {{ return(dbt_context_engineering.vocabulary_schema(name, version)) }}
{%- endmacro %}


{#-
  vocabulary_delta_predicate(id_column, name=none, version=none, review_relation=none, method=none) -> the predicate
  selecting the rows vocabulary_decide processes this run, or none for every row. Share it across
  the model body, guard_batch and log_ai_run, the incremental_delta_predicate contract.

  Re-decides a row only when it is new, its content_hash changed, or the vocabulary key changed
  (vocabulary version or method, via version_guard). A row with a human review is never sent to
  the model, on any run: its reviewed term wins in vocabulary_labels regardless, so re-deciding it
  would only spend. The input relation must carry id_column, the text, and content_hash.
-#}
{% macro vocabulary_delta_predicate(id_column, name=none, version=none, review_relation=none, method=none) -%}
    {%- set base = dbt_context_engineering.incremental_delta_predicate(
        id_column, dbt_context_engineering.vocabulary_key(name, version, method), 'vocabulary_key',
        content_hash_column='content_hash') -%}
    {%- set reviewed = none -%}
    {%- if review_relation is not none -%}
        {#- not null in the subquery: one null id would make NOT IN exclude every row -#}
        {%- set reviewed = id_column ~ " not in (select " ~ id_column ~ " from " ~ review_relation
            ~ " where " ~ id_column ~ " is not null and approved_term is not null)" -%}
    {%- endif -%}
    {%- if base is none -%}{{ return(reviewed) }}{%- endif -%}
    {%- if reviewed is none -%}{{ return(base) }}{%- endif -%}
    {{ return('(' ~ base ~ ') and ' ~ reviewed) }}
{%- endmacro %}


{#-
  vocabulary_decide(relation, id_column, text_column, name=none, version=none, filter=none) -> a SELECT for an
  incremental model (unique_key=id_column): one AI call per row in the batch, raw result stored.

  Columns: <id_column>, content_hash, vocabulary_name, vocabulary_version, vocabulary_key, method,
  decision (decide's raw result, null on the classify path), classified_term (classify's label,
  null on the decide path), decided_at.

  Switching method (e.g. turning on decide_snowflake_preview) changes the decision column's type;
  run that build with --full-refresh.
-#}
{% macro vocabulary_decide(relation, id_column, text_column, name=none, version=none, filter=none) -%}
    {%- set method = dbt_context_engineering.vocabulary_method() -%}
    {%- set ref_ = dbt_context_engineering.vocabulary_ref(name, version) -%}
    {#- resolved name/version pass through (none during parse, where vocabulary() returns its
        placeholder); the *_lit forms are what lands in SQL literals -#}
    {%- set name = ref_[0] -%}
    {%- set version = ref_[1] -%}
    {%- set name_lit = name or 'placeholder' -%}
    {%- set version_lit = version or 'v0' -%}
    {%- set str_t = dbt.type_string() -%}
select
    {{ id_column }},
    content_hash,
    {{ dbt_context_engineering.str_literal(name_lit) }}    as vocabulary_name,
    {{ dbt_context_engineering.str_literal(version_lit) }} as vocabulary_version,
    {{ dbt_context_engineering.str_literal(dbt_context_engineering.vocabulary_key(name, version, method)) }} as vocabulary_key,
    {{ dbt_context_engineering.str_literal(method) }}  as method,
    {%- if method == 'decide' %}
    {{ dbt_context_engineering.decide(text_column, dbt_context_engineering.vocabulary_question(name, version)) }} as decision,
    cast(null as {{ str_t }}) as classified_term,
    {%- else %}
    cast(null as {{ str_t }}) as decision,
    {{ dbt_context_engineering.classify(text_column,
        dbt_context_engineering.vocabulary_prompt(name, version),
        dbt_context_engineering.vocabulary_schema(name, version)) }} as classified_term,
    {%- endif %}
    {{ dbt.current_timestamp() }} as decided_at
from {{ relation }}
{%- if filter %}
where {{ filter }}
{%- endif %}
{%- endmacro %}


{#-
  vocabulary_labels(decided_relation, id_column, name=none, version=none, threshold=none,
                    review_relation=none, method=none) -> a SELECT over vocabulary_decide's output.
  No AI call.

  Columns: <id_column>, term, confidence, runner_up, runner_up_probability, method, decision_model,
  vocabulary_name, vocabulary_version, status, approved_term, reviewer, reviewed_at, final_term,
  final_status, error.

  status (the model's call): 'accepted' when confidence >= threshold, 'needs_review' below it or
  when the answer is missing, errored or not an active term, 'unscored' on the classify path
  (a valid label from a method with no confidence to route on). threshold is required on the
  decide path; set it per vocabulary from a golden set (eval with confidence_column).

  review_relation: a user-owned relation the package only reads, with <id_column>, approved_term,
  reviewer, reviewed_at. The latest review per id wins over the model on join: final_term is the
  approved term when present, else the term for 'accepted' / 'unscored' rows, else null.
  final_status is 'reviewed' for those rows, else status. Omitted, the join is skipped.

  method defaults to vocabulary_method(); pass it to read a decided relation built elsewhere.
  Raises at execute time if decided_relation holds rows decided with a different vocabulary key
  (vocabulary_require_in_sync).
-#}
{% macro vocabulary_labels(decided_relation, id_column, name=none, version=none, threshold=none, review_relation=none, method=none) -%}
    {%- set method = method or dbt_context_engineering.vocabulary_method() -%}
    {%- set ref_ = dbt_context_engineering.vocabulary_ref(name, version) -%}
    {#- resolved name/version pass through (none during parse, where vocabulary() returns its
        placeholder); the *_lit forms are what lands in SQL literals -#}
    {%- set name = ref_[0] -%}
    {%- set version = ref_[1] -%}
    {%- set name_lit = name or 'placeholder' -%}
    {%- set version_lit = version or 'v0' -%}
    {%- set labels = dbt_context_engineering.vocabulary_labels_list(name, version) -%}
    {%- set str_t = dbt.type_string() -%}
    {%- set float_t = dbt.type_float() -%}
    {%- if method == 'decide' and threshold is none and execute -%}
        {{ exceptions.raise_compiler_error("vocabulary_labels: threshold is required on the decide path. Set it per vocabulary from a golden set (eval with confidence_column).") }}
    {%- endif -%}
    {%- if execute -%}
        {%- do dbt_context_engineering.vocabulary_require_in_sync(decided_relation,
            dbt_context_engineering.vocabulary_key(name, version, method)) -%}
    {%- endif -%}
    {%- set label_list -%}({% for l in labels %}{{ dbt_context_engineering.str_literal(l) }}{% if not loop.last %}, {% endif %}{% endfor %}){%- endset %}
with _decided as (
    select * from {{ decided_relation }}
),
{%- if method == 'decide' %}
_flat as (
    select
        {{ id_column }},
        vocabulary_name,
        vocabulary_version,
        method,
        {{ dbt_context_engineering.decide_answer('decision', 'term', 'choice') }}                as term,
        {{ dbt_context_engineering.decide_answer('decision', 'term', 'confidence', float_t) }}   as confidence,
        {{ dbt_context_engineering.decide_model('decision') }}                                   as decision_model,
        {{ dbt_context_engineering.decide_error('decision') }}                                   as error
    from _decided
),
_probs as (
    {%- for l in labels %}
    select {{ id_column }}, {{ dbt_context_engineering.str_literal(l) }} as label,
           {{ dbt_context_engineering.decide_answer('decision', 'term', 'probabilities.' ~ l, float_t) }} as p
    from _decided
    {%- if not loop.last %}
    union all
    {%- endif %}
    {%- endfor %}
),
_ranked as (
    {#- runner-up: the most probable active term other than the one chosen; ties break by label -#}
    select pr.{{ id_column }}, pr.label, pr.p,
           row_number() over (partition by pr.{{ id_column }} order by pr.p desc, pr.label) as rn
    from _probs pr
    join _flat f on f.{{ id_column }} = pr.{{ id_column }}
    where pr.p is not null and (f.term is null or pr.label <> f.term)
),
_scored as (
    select
        f.{{ id_column }},
        f.term,
        f.confidence,
        r.label as runner_up,
        r.p     as runner_up_probability,
        f.method,
        f.decision_model,
        f.vocabulary_name,
        f.vocabulary_version,
        case
            when f.error is not null or f.term is null or f.term not in {{ label_list }} then 'needs_review'
            when f.confidence >= {{ threshold if threshold is not none else 1 }} then 'accepted'
            else 'needs_review'
        end as status,
        f.error
    from _flat f
    left join _ranked r
        on r.{{ id_column }} = f.{{ id_column }} and r.rn = 1
),
{%- else %}
_scored as (
    select
        {{ id_column }},
        classified_term as term,
        cast(null as {{ float_t }}) as confidence,
        cast(null as {{ str_t }})   as runner_up,
        cast(null as {{ float_t }}) as runner_up_probability,
        method,
        cast({{ dbt_context_engineering.str_literal('classify/' ~ (var('model_classify', none) or 'default')) }} as {{ str_t }}) as decision_model,
        vocabulary_name,
        vocabulary_version,
        case when classified_term in {{ label_list }} then 'unscored' else 'needs_review' end as status,
        cast(null as {{ str_t }})   as error
    from _decided
),
{%- endif %}
{%- if review_relation is not none %}
_reviews as (
    select {{ id_column }}, approved_term, reviewer, reviewed_at
    from (
        select {{ id_column }}, approved_term, reviewer, reviewed_at,
               row_number() over (partition by {{ id_column }} order by reviewed_at desc) as _rn
        from {{ review_relation }}
        where {{ id_column }} is not null and approved_term is not null
    ) as _latest
    where _rn = 1
),
_joined as (
    select
        coalesce(s.{{ id_column }}, rv.{{ id_column }}) as {{ id_column }},
        s.term, s.confidence, s.runner_up, s.runner_up_probability, s.method, s.decision_model,
        coalesce(s.vocabulary_name, {{ dbt_context_engineering.str_literal(name_lit) }})       as vocabulary_name,
        coalesce(s.vocabulary_version, {{ dbt_context_engineering.str_literal(version_lit) }}) as vocabulary_version,
        s.status,
        cast(rv.approved_term as {{ str_t }}) as approved_term,
        cast(rv.reviewer as {{ str_t }})      as reviewer,
        rv.reviewed_at,
        s.error
    from _scored s
    full outer join _reviews rv
        on rv.{{ id_column }} = s.{{ id_column }}
)
{%- else %}
_joined as (
    select
        {{ id_column }}, term, confidence, runner_up, runner_up_probability, method, decision_model,
        vocabulary_name, vocabulary_version, status,
        cast(null as {{ str_t }}) as approved_term,
        cast(null as {{ str_t }}) as reviewer,
        cast(null as {{ dbt.type_timestamp() }}) as reviewed_at,
        error
    from _scored
)
{%- endif %}
select
    {{ id_column }},
    term,
    confidence,
    runner_up,
    runner_up_probability,
    method,
    decision_model,
    vocabulary_name,
    vocabulary_version,
    status,
    approved_term,
    reviewer,
    reviewed_at,
    coalesce(approved_term, case when status in ('accepted', 'unscored') then term end) as final_term,
    case when approved_term is not null then 'reviewed' else status end as final_status,
    error
from _joined
{%- endmacro %}


{#- vocabulary_require_in_sync(decided_relation, expected_key) -> raises when the decided relation
    holds rows stamped with any other vocabulary key (name@version/method). Guards the two-model
    pipeline against version skew: a labels model reading answers decided against a different
    vocabulary would misroute rows (terms retired in the new version go to review, the runner-up
    reads labels the answers never had) while the build stays green. One small metadata query at
    execute time, the same kind version_guard runs; an empty relation passes. -#}
{% macro vocabulary_require_in_sync(decided_relation, expected_key) -%}
    {%- set result = run_query("select distinct vocabulary_key from " ~ decided_relation
        ~ " where vocabulary_key is not null") -%}
    {%- set found = result.columns[0].values() | list if result is not none else [] -%}
    {%- set stale = found | reject('equalto', expected_key) | list -%}
    {%- if stale -%}
        {{ exceptions.raise_compiler_error(
            "vocabulary_labels: " ~ decided_relation ~ " holds rows decided with "
            ~ (stale | sort | join(', ')) ~ ", but this model reads " ~ expected_key ~ ". Rebuild "
            ~ decided_relation ~ ", or align both models' meta.ai_vocabulary.") }}
    {%- endif -%}
{%- endmacro %}


{#-
  vocabulary_rows(name, version) -> a SELECT of one row per term, every status, for a
  dim_vocabulary model consumers join to: vocabulary_name, vocabulary_version, term_label,
  definition, scope_note, status, valid_from, valid_to, synonyms ('; '-joined). No AI call.
-#}
{% macro vocabulary_rows(name=none, version=none) -%}
    {%- set ref_ = dbt_context_engineering.vocabulary_ref(name, version) -%}
    {#- resolved name/version pass through (none during parse, where vocabulary() returns its
        placeholder); the *_lit forms are what lands in SQL literals -#}
    {%- set name = ref_[0] -%}
    {%- set version = ref_[1] -%}
    {%- set name_lit = name or 'placeholder' -%}
    {%- set version_lit = version or 'v0' -%}
    {%- set v = dbt_context_engineering.vocabulary(ref_[0], ref_[1]) -%}
    {%- set str_t = dbt.type_string() -%}
    {%- for t in v.terms %}
select
    cast({{ dbt_context_engineering.str_literal(name_lit) }} as {{ str_t }})                 as vocabulary_name,
    cast({{ dbt_context_engineering.str_literal(version_lit) }} as {{ str_t }})              as vocabulary_version,
    cast({{ dbt_context_engineering.str_literal(t.label) }} as {{ str_t }})              as term_label,
    cast({{ dbt_context_engineering.str_literal(t.definition) }} as {{ str_t }})         as definition,
    cast({{ dbt_context_engineering.str_literal(t.scope_note) if t.get('scope_note') else 'null' }} as {{ str_t }}) as scope_note,
    cast({{ dbt_context_engineering.str_literal(t.get('status', 'active')) }} as {{ str_t }}) as status,
    cast({{ dbt_context_engineering.str_literal(t.valid_from) if t.get('valid_from') else 'null' }} as date) as valid_from,
    cast({{ dbt_context_engineering.str_literal(t.valid_to) if t.get('valid_to') else 'null' }} as date)     as valid_to,
    cast({{ dbt_context_engineering.str_literal(t.synonyms | join('; ')) if t.get('synonyms') else 'null' }} as {{ str_t }}) as synonyms
{%- if not loop.last %}
union all
{%- endif %}
    {%- endfor %}
{%- endmacro %}

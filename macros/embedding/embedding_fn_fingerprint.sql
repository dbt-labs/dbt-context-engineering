{#-
  embedding_fn_fingerprint(model=none, dimension=none, extra=none) -> a compile-time hash literal
  (plain hex string, not pre-quoted) identifying everything that defines the embed() CALL besides
  the input text: model identity, a configured dimension/truncation parameter, and any other
  vector-affecting provider parameter. Resolved once in Jinja, the same way prompt()/schema()
  resolve to compile-time literals; none of these inputs are per-row data.

  Scope, per ADR-0023's resolved open decisions:
    - Chunking/preprocessing config is deliberately NOT an input here. Any change to it that
      actually alters the assembled text already surfaces as a content_hash mismatch; folding it
      in here would only duplicate that.
    - Code identity of the embed() wrapper itself is deliberately NOT an input here either. See
      embedding_logic_hash(), a separate audit column that never gates reprocessing.
    - `dimension` here means a CONFIGURED/REQUESTED dimension-truncation parameter (e.g. a future
      embed(..., dimension=768)), not the observed per-row embedding_dimension column. embed() has
      no such parameter today, so this is always none in practice, a forward-compatible
      placeholder rather than dead weight: the day embed() gains one, the fingerprint changes
      without anyone having to remember to come back and add it.
    - No "prefer the echoed model snapshot" branch. No engine echoes a resolved model snapshot at
      the SQL-function layer; var('embedding_model') is the only source of model identity on
      Snowflake, Databricks, and BigQuery.

  `model` defaults to var('embedding_model'), the same resolution embed() itself uses, so the two
  never disagree about which model they mean. Compares equal for equal inputs regardless of key
  order, serialized from a sorted key list, not a raw dict repr, so this is stable across
  Jinja/Python versions and doesn't depend on dict ordering.

  Uses dbt's own local_md5() (Jinja-level MD5, not a SQL command) rather than the `modules` context
  variable, which only exposes pytz/datetime/re/itertools, not hashlib. Collision resistance
  doesn't matter here the way it does for content_hash: this is a change-detection key over a
  handful of low-entropy config values, not a cryptographic commitment over row data.
-#}

{% macro embedding_fn_fingerprint(model=none, dimension=none, extra=none) -%}
    {%- set model = model if model is not none else var('embedding_model', none) -%}
    {%- if model is none -%}
        {#- execute-gated, same reasoning as require_ai_functions_enabled (see
            require_prerequisites.sql): dbt's parse phase renders every model's Jinja to build
            the manifest regardless of --select, so an unguarded raise here breaks parsing of the
            whole project the moment any one model anywhere calls this, not just the model that
            does. A placeholder is fine at parse time since the result is never executed. -#}
        {%- if execute -%}
            {{ exceptions.raise_compiler_error(
                "embedding_fn_fingerprint: set var embedding_model or pass model=.") }}
        {%- else -%}
            {%- set model = 'unset' -%}
        {%- endif -%}
    {%- endif -%}

    {%- set canonical = {'model': model, 'dimension': dimension, 'extra': extra} -%}
    {%- set parts = [] -%}
    {%- for k in canonical.keys() | sort -%}
        {%- do parts.append(k ~ '=' ~ (canonical[k] | string)) -%}
    {%- endfor -%}
    {%- set serialized = parts | join('&') -%}

    {{ return(local_md5(serialized)) }}
{%- endmacro %}

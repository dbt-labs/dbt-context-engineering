{#-
  Fail-fast prerequisite checks (spec §2.2). The divergences must fail with a clear, actionable
  message, never an opaque SQL error.

  Every check here is execute-gated. dbt's parse phase (execute=False) renders EVERY model's Jinja
  to build the manifest, regardless of --select, so an unguarded raise breaks parsing of the WHOLE
  project the moment any one model anywhere calls an AI function. Confirmed live: building only
  `split_docs chunk_docs` failed on a Compilation Error in `generate_text`, a model that was not
  selected at all, before the guard was added. The run phase (execute=True) re-renders only the
  models actually selected, which scopes each check to a model that is really about to fire.
-#}


{% macro require_databricks_ai_runtime() -%}
    {#- NOT IMPLEMENTED. The body is empty. The macro exists so the prerequisite is visible at
        the point where it would be enforced, rather than living only in prose.

        The prerequisite, per Databricks' own docs: AI functions require DBR 15.4 LTS or above
        and are not available on Databricks SQL Classic. DBR 18.2+ is RECOMMENDED, not required,
        and Pro is supported.

        Enforcing it needs a live `select current_version()` round trip at compile time on every
        AI-calling model, which is a cost and a design decision rather than a mechanical fix, and
        it cannot be validated without a Databricks warehouse. Until that lands, an unmet
        prerequisite surfaces as an opaque SQL error at build time rather than a compiler error
        naming the cause. See README.md's macro reference and TESTING.md §5's
        `assert_wrappers_nonnull` row for the manual cross-check that stands in. -#}
{%- endmacro %}


{% macro require_ai_functions_enabled(fn_name) -%}
    {#- Off by default so a fresh or CI target can never accidentally trigger a real, billed AI
        call just by running `dbt build`. Called from generate/classify/extract/embed/ai_agg's own
        outer macro, the adapter-agnostic entry point before adapter.dispatch, so anyone who calls
        the function unavoidably runs this check rather than opting into it.

        The value is normalized to text and compared, NOT tested for truthiness. Jinja in
        dbt_project.yml is rendered into the YAML text before the YAML is parsed, and the
        expression has to be quoted, so any templated value arrives here as a string. Every
        non-empty string is truthy in Jinja, so a truthiness test reads "false" as ON. That would
        turn the obvious way to write "allow AI in prod only",
        `ai_functions_enabled: "{{ 'true' if target.name == 'prod' else 'false' }}"`, into a gate
        open on every target. Confirmed live, including with `| as_bool`, which does not rescue
        it. An unrecognized value raises rather than being read as off, so a typo is a stopped run
        and not a gate that quietly does nothing. -#}
    {%- set raw = var('ai_functions_enabled', false) -%}
    {%- set normalized = raw | string | trim | lower -%}
    {%- if execute and normalized not in ['true', 'false'] -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): var ai_functions_enabled must be true or false, got '" ~ raw ~ "'. "
            ~ "Note that a Jinja expression in dbt_project.yml always produces a string, so write "
            ~ "a value that reads as 'true' or 'false' after rendering."
        ) }}
    {%- endif -%}
    {%- if execute and normalized != 'true' -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): AI functions are disabled by default. Set var ai_functions_enabled: "
            ~ "true for this target to allow a real AI call to fire."
        ) }}
    {%- endif -%}
{%- endmacro %}


{% macro require_safe_materialization(fn_name) -%}
    {#- is_incremental() is always false for a view, so a model wrapping an AI function takes
        the "process everything" branch on every SELECT against it, not once per dbt run but
        every time anyone queries it: an unbounded, repeated cost, not a tradeoff the way
        table vs. incremental is. config.get('materialized') resolves correctly from inside a
        macro regardless of call depth.

        Deliberately does NOT block 'table'. A plain table reprocesses the full corpus every run
        too, a milder form of the same problem, but table is a real, sometimes-correct choice
        (embedding_canary is table on purpose, a small fixed probe set re-embedded every build by
        design), not an unconditional mistake the way view always is. Flagging table would be a
        false positive for a legitimate pattern this package itself ships.

        Compares against a string literal rather than testing truthiness, so the failure mode
        require_ai_functions_enabled documents does not apply here. -#}
    {%- if execute and config.get('materialized') == 'view' -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): materialized='view' recomputes this call on every query against this "
            ~ "model, an unbounded, repeated cost, not a one-time cost per dbt run. Use 'table' "
            ~ "or 'incremental' instead."
        ) }}
    {%- endif -%}
{%- endmacro %}


{% macro require_full_refresh_gate(fn_name) -%}
    {#- Only meaningful for materialized='incremental'. 'view' is already blocked by
        require_safe_materialization; 'table' fully rebuilds on every plain `dbt run` regardless
        of --full-refresh, so there is nothing extra for this flag to gate there.

        dbt's OWN full_refresh config key, when a model sets it, overrides whether a bare
        --full-refresh CLI flag does anything for that node (independent of this package
        entirely). Left unset, config.get('full_refresh') resolves to Jinja `none`; once a model
        sets it to anything, even `false`, it resolves to that real value instead. Confirmed live
        via a throwaway probe model compiled both ways. This macro does not care WHICH value was
        chosen, only that the model made a deliberate choice instead of leaving dbt's own default
        (a bare --full-refresh always fully reprocesses) silently in force on an AI-calling model.
        Testing for `is none` rather than truthiness is what makes an explicit `false` count as a
        choice, so the failure mode require_ai_functions_enabled documents does not apply here.

        version_guard's own state-driven full reprocess (a real version/fingerprint bump) is
        untouched by this: it fires on its own, independent of --full-refresh and this config key
        entirely. This macro only closes the gap version_guard doesn't cover, an UNRELATED
        --full-refresh on a shared job re-triggering AI spend on a model that didn't change. -#}
    {%- if execute and config.get('materialized') == 'incremental' and config.get('full_refresh') is none -%}
        {{ exceptions.raise_compiler_error(
            fn_name ~ "(): materialized='incremental' with no full_refresh config leaves this "
            ~ "model's AI cost exposed to any bare --full-refresh, even one run for an unrelated "
            ~ "reason on a shared job. Set full_refresh=var('allow_full_reembed', false) (or "
            ~ "similar) so a reprocess requires an explicit opt-in."
        ) }}
    {%- endif -%}
{%- endmacro %}

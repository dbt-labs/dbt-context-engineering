{#-
  chunk_fn_fingerprint(...) -> a compile-time hash literal (plain hex, not pre-quoted) identifying
  everything that defines a chunk() CALL besides the input rows: the token budget, the overlap, the
  join separator, and which columns are read. Resolved once in Jinja, the same way
  embedding_fn_fingerprint() resolves; none of these inputs are per-row data.

  Why chunk needs its own fingerprint when embedding_fn_fingerprint() deliberately excludes chunking
  config: that exclusion is correct from embed()'s side, because a chunking change that alters the
  assembled text already surfaces to embed() as a content_hash mismatch on chunk_text. It does not
  hold from chunk()'s own side. chunk()'s partition hash is taken over its INPUT units, so a pure
  config change (a different target_tokens, say) leaves every input byte identical while completely
  re-cutting the output. Without this fingerprint folded in, no partition looks dirty, nothing
  rebuilds, and an incremental chunk model serves output built under the previous configuration
  indefinitely while reporting success. Confirmed live: dropping target_tokens from 20 to 6 changed
  a duckdb fixture from 4 rows to 9 on a full refresh, while the incremental run returned the
  original 4 rows with byte-identical partition hashes.

  Scope:
    - Every argument that changes chunk()'s output for fixed input rows is an input here. Column
      NAMES are included, not just their values, because re-pointing text_column at a different
      column re-cuts every chunk while the relation itself is untouched.
    - Code identity of chunk() itself is NOT an input, mirroring the embed() split: see
      embedding_logic_hash() for that separate, CI-verified audit-only pattern. A change to chunk's
      packing algorithm therefore needs a --full-refresh, exactly as it does for embed().

  Returned as hex, so callers can embed it directly in a SQL string literal with no escaping. That
  matters because join_separator defaults to a real newline, which is not portable to write into a
  literal (BigQuery rejects raw newlines in single-quoted strings); hashing it in Jinja first sides
  steps the problem entirely.

  Uses dbt's own local_md5() (Jinja-level MD5, not a SQL command), same as
  embedding_fn_fingerprint(). Collision resistance is not the property being bought here: this is
  change detection over a handful of low-entropy config values, not a commitment over row data.
  Serialized from a sorted key list so equal inputs compare equal regardless of dict ordering.
-#}

{% macro chunk_fn_fingerprint(target_tokens, overlap_tokens, join_separator,
                              id_column, order_column, text_column,
                              partition_column=none, label_column=none, extra=none) -%}
    {%- set canonical = {
        'target_tokens': target_tokens,
        'overlap_tokens': overlap_tokens,
        'join_separator': join_separator,
        'id_column': id_column,
        'order_column': order_column,
        'text_column': text_column,
        'partition_column': partition_column,
        'label_column': label_column,
        'extra': extra
    } -%}
    {%- set parts = [] -%}
    {%- for k in canonical.keys() | sort -%}
        {%- do parts.append(k ~ '=' ~ (canonical[k] | string)) -%}
    {%- endfor -%}

    {{ return(local_md5(parts | join('&'))) }}
{%- endmacro %}

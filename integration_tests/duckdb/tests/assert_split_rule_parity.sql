{#- Cross-engine boundary-rule parity for split_sentences (finding #7). The default/BigQuery/Databricks
    impls split on regexp_extract_all('[^.!?]+[.!?]*'); Snowflake has no regexp_extract_all and instead
    strips a leading terminator run then inserts a sentinel after every terminator run. This asserts the
    two rules produce the SAME ordered, trimmed, non-empty sentence list over tricky inputs (decimals,
    consecutive terminators, leading terminators, no terminator). Both rules are evaluated here in duckdb
    so the comparison is deterministic and credential-free; a divergence (like the old whitespace-only
    Snowflake rule) returns the offending document_id. Actual Snowflake execution is LIVE-VALIDATION
    DEFERRED, but the rule it implements is pinned equal to the canonical one here. -#}
with cases as (
    select * from (values
        ('a', 'Data pipelines break often. Observability is the core need! Can we see which failed?'),
        ('b', 'Section 3.2 is ready. Ship it.'),
        ('c', 'A single sentence with no terminator'),
        ('d', 'Wait!? Really'),
        ('e', 'Multiple... dots and spaces.  Then more.'),
        ('f', '...leading terminators then text.'),
        ('g', '')
    ) as t(document_id, document_text)
),
default_rule as (   -- regexp_extract_all('[^.!?]+[.!?]*'), as default/BigQuery/Databricks do
    select document_id, list(trim(s) order by n) as sents
    from (
        select document_id, u.s as s, u.n as n
        from cases, unnest(regexp_extract_all(document_text, '[^.!?]+[.!?]*')) with ordinality as u(s, n)
    ) t
    where trim(s) <> ''
    group by document_id
),
snowflake_rule as (   -- strip leading terminators, sentinel after every terminator run, then split
    select document_id, list(trim(s) order by n) as sents
    from (
        select document_id, u.s as s, u.n as n
        from cases,
             unnest(string_split(
                 regexp_replace(regexp_replace(document_text, '^[.!?]+', '', 'g'), '([.!?]+)', '\1~~CE_SENT~~', 'g'),
                 '~~CE_SENT~~'
             )) with ordinality as u(s, n)
    ) t
    where trim(s) <> ''
    group by document_id
)
select coalesce(d.document_id, s.document_id) as document_id
from default_rule d
full outer join snowflake_rule s using (document_id)
where d.sents is distinct from s.sents

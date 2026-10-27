-- Redshift treats backslash as an escape char in string literals, so str_literal must DOUBLE it
-- (redshift__str_literal) or a prompt with a regex/path is silently corrupted. Round-trips a few
-- special-char strings and checks the rendered literal evaluates back to the original. chr(92) is a
-- literal backslash, used for the expected value so the comparison itself isn't backslash-mangled.
-- Fail rows only.
with r as (
    select
        {{ dbt_context_engineering.str_literal('a\\d+b') }}        as backslash_val,
        {{ dbt_context_engineering.str_literal('C:\\Users\\x') }}  as path_val,
        {{ dbt_context_engineering.str_literal("it's \"ok\"") }}   as quote_val,
        {{ dbt_context_engineering.str_literal('line1\nline2') }}  as newline_val
)
select 'backslash_corrupted' as issue from r where backslash_val <> ('a' || chr(92) || 'd+b')
union all select 'path_corrupted'   from r where path_val     <> ('C:' || chr(92) || 'Users' || chr(92) || 'x')
union all select 'quote_corrupted'  from r where quote_val    <> ('it''s "ok"')
union all select 'newline_corrupted' from r where newline_val <> ('line1' || chr(10) || 'line2')

-- 00_profile.sql
-- Data quality checks on stg_events (from 00_stage). Each "-- name:" block is saved as a CSV.


-- name: overview
-- Row, user, session counts and time span.
SELECT
    COUNT(*)                    AS n_rows,
    COUNT(DISTINCT ID_HASH)     AS n_distinct_ids,
    COUNT(DISTINCT USER_ID)     AS n_users,
    COUNT(DISTINCT SESSION_ID)  AS n_sessions,
    COUNT(DISTINCT SUBDOMAIN)   AS n_subdomains,
    MIN(CREATED_TIME)           AS first_event_utc,
    MAX(CREATED_TIME)           AS last_event_utc,
    DATE_DIFF('day', MIN(CREATED_TIME), MAX(CREATED_TIME)) + 1 AS n_days
FROM stg_events;


-- name: completeness
-- NULLs and empty strings per column (flags set in staging, before hashing).
SELECT
    SUM(CASE WHEN miss_time      THEN 1 ELSE 0 END) AS null_created_time,
    SUM(CASE WHEN miss_user      THEN 1 ELSE 0 END) AS null_or_empty_user_id,
    SUM(CASE WHEN miss_subdomain THEN 1 ELSE 0 END) AS null_or_empty_subdomain,
    SUM(CASE WHEN miss_url       THEN 1 ELSE 0 END) AS null_or_empty_url,
    SUM(CASE WHEN miss_session   THEN 1 ELSE 0 END) AS null_or_empty_session_id,
    SUM(CASE WHEN miss_id        THEN 1 ELSE 0 END) AS null_or_empty_id
FROM stg_events;


-- name: uniqueness
-- Duplicate _IDs, and same user + time + URL logged under different _IDs.
SELECT
    (SELECT COUNT(*) FROM (SELECT ID_HASH FROM stg_events GROUP BY ID_HASH HAVING COUNT(*) > 1))
        AS n_duplicated_ids,
    (SELECT COUNT(*) - COUNT(DISTINCT ID_HASH) FROM stg_events)
        AS n_extra_rows_from_dup_ids,
    (SELECT COUNT(*) FROM (
        SELECT USER_ID, CREATED_TIME, url_hash FROM stg_events
        GROUP BY ALL HAVING COUNT(DISTINCT ID_HASH) > 1))
        AS n_logical_duplicate_groups;


-- name: dup_id_examples
-- Are duplicate _IDs exact copies?
SELECT ID_HASH                      AS _ID,
       COUNT(*)                     AS n_rows,
       COUNT(DISTINCT url_hash)     AS n_distinct_urls,
       COUNT(DISTINCT CREATED_TIME) AS n_distinct_times
FROM stg_events
GROUP BY ID_HASH
HAVING COUNT(*) > 1
ORDER BY n_rows DESC, _ID
LIMIT 20;


-- name: validity_url
-- URL format; SUBDOMAIN vs. host parsed from the URL.
SELECT
    COUNT(*)                                                         AS n_rows,
    SUM(CASE WHEN NOT is_http THEN 1 ELSE 0 END)                      AS n_non_http_urls,
    SUM(CASE WHEN url_host IS NULL OR url_host = '' THEN 1 ELSE 0 END) AS n_unparseable_host,
    SUM(CASE WHEN url_host <> LOWER(SUBDOMAIN) THEN 1 ELSE 0 END)     AS n_host_mismatch,
    ROUND(100.0 * SUM(CASE WHEN url_host <> LOWER(SUBDOMAIN) THEN 1 ELSE 0 END) / COUNT(*), 3)
                                                                     AS pct_host_mismatch
FROM stg_events;


-- name: host_mismatch_examples
SELECT SUBDOMAIN, url_host, COUNT(*) AS n
FROM stg_events
WHERE url_host <> LOWER(SUBDOMAIN)
GROUP BY ALL
ORDER BY n DESC, SUBDOMAIN, url_host
LIMIT 25;


-- name: session_consistency
-- One user per session? Crosses midnight? How long?
WITH s AS (
    SELECT SESSION_ID,
           COUNT(DISTINCT USER_ID)                    AS n_users,
           COUNT(DISTINCT CAST(CREATED_TIME AS DATE)) AS n_utc_days,
           DATE_DIFF('minute', MIN(CREATED_TIME), MAX(CREATED_TIME)) AS duration_min,
           COUNT(*)                                   AS n_events
    FROM stg_events
    GROUP BY SESSION_ID
)
SELECT
    COUNT(*)                                          AS n_sessions,
    SUM(CASE WHEN n_users > 1 THEN 1 ELSE 0 END)      AS sessions_multi_user,
    SUM(CASE WHEN n_utc_days > 1 THEN 1 ELSE 0 END)   AS sessions_cross_utc_midnight,
    QUANTILE_CONT(duration_min, 0.5)                  AS median_duration_min,
    QUANTILE_CONT(duration_min, 0.99)                 AS p99_duration_min,
    MAX(duration_min)                                 AS max_duration_min,
    QUANTILE_CONT(n_events, 0.5)                      AS median_events_per_session,
    MAX(n_events)                                     AS max_events_per_session
FROM s;


-- name: max_gap_within_session
-- Gaps between events in a session: can sessions be used as journeys?
WITH g AS (
    SELECT DATE_DIFF('second',
                     LAG(CREATED_TIME) OVER (PARTITION BY SESSION_ID ORDER BY CREATED_TIME),
                     CREATED_TIME) AS gap_s
    FROM stg_events
)
SELECT QUANTILE_CONT(gap_s, 0.5)   AS p50_gap_s,
       QUANTILE_CONT(gap_s, 0.9)   AS p90_gap_s,
       QUANTILE_CONT(gap_s, 0.99)  AS p99_gap_s,
       MAX(gap_s)                  AS max_gap_s
FROM g
WHERE gap_s IS NOT NULL;


-- name: user_activity_distribution
-- Events per user: heavy tail = possible bots.
WITH u AS (
    SELECT USER_ID, COUNT(*) AS n_events, COUNT(DISTINCT CAST(CREATED_TIME AS DATE)) AS n_days
    FROM stg_events GROUP BY USER_ID
)
SELECT
    QUANTILE_CONT(n_events, 0.50)  AS p50_events,
    AVG(n_events)                  AS mean_events,
    QUANTILE_CONT(n_events, 0.90)  AS p90_events,
    QUANTILE_CONT(n_events, 0.99)  AS p99_events,
    MAX(n_events)                  AS max_events,
    QUANTILE_CONT(n_days, 0.50)    AS p50_active_days,
    MAX(n_days)                    AS max_active_days
FROM u;


-- name: daily_volume
-- Events per day.
SELECT CAST(CREATED_TIME AS DATE) AS day_utc,
       COUNT(*)                   AS n_events,
       COUNT(DISTINCT USER_ID)    AS n_users
FROM stg_events
GROUP BY 1
ORDER BY 1;


-- name: hour_of_day_utc
-- No country column: a US panel should peak in US daytime (~14:00-03:00 UTC).
SELECT EXTRACT(hour FROM CREATED_TIME) AS hour_utc,
       COUNT(*)                        AS n_events,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM stg_events
GROUP BY 1
ORDER BY 1;


-- name: tld_mix
-- Second US check: top-level domains.
SELECT REGEXP_EXTRACT(LOWER(SUBDOMAIN), '\.([a-z]+)$', 1) AS tld,
       COUNT(*)                                          AS n_events,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM stg_events
GROUP BY 1
ORDER BY n_events DESC, tld
LIMIT 30;


-- name: top_subdomains
SELECT SUBDOMAIN, COUNT(*) AS n_events, COUNT(DISTINCT USER_ID) AS n_users
FROM stg_events
GROUP BY 1
ORDER BY n_events DESC, SUBDOMAIN
LIMIT 50;


-- name: brand_domain_coverage
-- All brand hosts, incl. non-US ones to exclude.
SELECT
    CASE
        WHEN SUBDOMAIN ILIKE '%saatva%'            THEN 'saatva'
        WHEN SUBDOMAIN ILIKE '%nectarsleep%'       THEN 'nectar'
        WHEN SUBDOMAIN ILIKE '%helixsleep%'        THEN 'helix'
        WHEN SUBDOMAIN ILIKE '%dreamcloudsleep%'   THEN 'dreamcloud'
        WHEN SUBDOMAIN ILIKE '%walmart%'           THEN 'walmart'
    END                      AS brand,
    SUBDOMAIN,
    COUNT(*)                 AS n_events,
    COUNT(DISTINCT USER_ID)  AS n_users
FROM stg_events
WHERE REGEXP_MATCHES(LOWER(SUBDOMAIN), 'saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart')
GROUP BY ALL
ORDER BY brand, n_events DESC, SUBDOMAIN;

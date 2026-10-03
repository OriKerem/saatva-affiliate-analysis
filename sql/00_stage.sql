-- 00_stage.sql
-- Read the Parquet files once into stg_events, so later steps don't rescan 12 GB each time.
-- Input: raw_events (filtered by run mode). Output: brand_users, stg_events.
-- IDs are stored as 64-bit hashes (smaller, faster joins; collisions negligible at this size).
-- Full URL and original _ID are kept only for brand users (~5% of rows).
-- Domain patterns match whole labels, e.g. (^|\.)bing\.com$, so plumbing.com is not Bing.


-- name: build_brand_users
-- Users who touched a brand, in the host or anywhere in the URL.
CREATE OR REPLACE TABLE brand_users AS
SELECT DISTINCT hash(USER_ID) AS USER_ID
FROM raw_events
WHERE REGEXP_MATCHES(SUBDOMAIN, '(?i)saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart')
   OR REGEXP_MATCHES(URL,       '(?i)saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart');


-- name: build_stg_events
CREATE OR REPLACE TABLE stg_events AS
WITH p AS (
    SELECT CREATED_TIME,
           hash(USER_ID)    AS USER_ID,
           hash(SESSION_ID) AS SESSION_ID,
           hash(_ID)        AS ID_HASH,
           _ID,
           SUBDOMAIN,
           URL,
           LOWER(REGEXP_EXTRACT(URL, '^[a-zA-Z]+://([^/?#:]+)', 1)) AS url_host,
           -- missing-value flags, before hashing (hash(NULL) is not NULL)
           CREATED_TIME IS NULL                              AS miss_time,
           USER_ID    IS NULL OR TRIM(USER_ID)    = ''       AS miss_user,
           SUBDOMAIN  IS NULL OR TRIM(SUBDOMAIN)  = ''       AS miss_subdomain,
           URL        IS NULL OR TRIM(URL)        = ''       AS miss_url,
           SESSION_ID IS NULL OR TRIM(SESSION_ID) = ''       AS miss_session,
           _ID        IS NULL OR TRIM(_ID)        = ''       AS miss_id
    FROM raw_events
),
h AS (
    SELECT p.*,
           REGEXP_REPLACE(COALESCE(NULLIF(url_host, ''), LOWER(SUBDOMAIN)), '^www\.', '') AS host,
           USER_ID IN (SELECT USER_ID FROM brand_users)                                 AS is_brand_user
    FROM p
)
SELECT CREATED_TIME,
       USER_ID,
       SESSION_ID,
       ID_HASH,
       SUBDOMAIN,
       url_host,
       host,
       hash(URL)                              AS url_hash,
       URL ILIKE 'http%://%'                  AS is_http,
       CASE
           WHEN host = 'saatva.com'          THEN 'saatva'
           WHEN host = 'nectarsleep.com'     THEN 'nectar'
           WHEN host = 'helixsleep.com'      THEN 'helix'
           WHEN host = 'dreamcloudsleep.com' THEN 'dreamcloud'
           WHEN host = 'walmart.com'         THEN 'walmart'
       END                                    AS brand,           -- main US shopping site only
       CASE
           WHEN REGEXP_MATCHES(URL, '(?i)^https?://(www\.)?google\.[a-z.]+/search')         THEN 'google search'
           WHEN REGEXP_MATCHES(URL, '(?i)^https?://(www\.)?bing\.com/search')               THEN 'bing search'
           WHEN REGEXP_MATCHES(URL, '(?i)^https?://(html\.)?duckduckgo\.com/(html/?)?\?q=') THEN 'duckduckgo search'
           WHEN REGEXP_MATCHES(URL, '(?i)^https?://search\.yahoo\.com/search')              THEN 'yahoo search'
           WHEN REGEXP_MATCHES(host, '(^|\.)google\.[a-z]{2,3}(\.[a-z]{2})?$')              THEN 'google, non-search page'
           WHEN REGEXP_MATCHES(URL, '(?i)^https?://[^/]+/search\?')                         THEN 'other site /search? page'
           WHEN REGEXP_MATCHES(host, '(^|\.)(bing|duckduckgo|yahoo)\.com$')                  THEN 'other bing / duckduckgo / yahoo page'
       END                                    AS search_page,
       is_brand_user,
       CASE WHEN is_brand_user THEN URL END   AS URL,              -- full URL only where needed
       CASE WHEN is_brand_user THEN _ID END   AS _ID,              -- original ID: deterministic journey order
       miss_time, miss_user, miss_subdomain, miss_url, miss_session, miss_id
FROM h;


-- name: stage_summary
-- Row and user counts after staging.
SELECT COUNT(*)                                              AS n_rows,
       SUM(CASE WHEN is_brand_user THEN 1 ELSE 0 END)        AS n_rows_with_url_kept,
       (SELECT COUNT(*) FROM brand_users)                    AS n_brand_users,
       SUM(CASE WHEN brand IS NOT NULL THEN 1 ELSE 0 END)    AS n_brand_site_rows,
       SUM(CASE WHEN search_page IS NOT NULL THEN 1 ELSE 0 END) AS n_search_engine_rows
FROM stg_events;

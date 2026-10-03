-- 01_param_discovery.sql
-- Find what affiliate traffic looks like in this data: brand hosts, URL parameters on landings,
-- and the pages people come from. Builds the dictionary from the data, not from a fixed list.
-- Needs brand_users / stg_events from 00_stage (same run mode).
-- Host = URL host, lower-case, without www. (SUBDOMAIN if the URL has no host).


-- name: build_brand_user_events
-- All events of brand users, with the previous / next event of the same user.
-- There is no referrer column, so the journey is rebuilt with LAG / LEAD.
CREATE OR REPLACE TABLE bu_events AS
SELECT USER_ID, SESSION_ID, _ID, CREATED_TIME, SUBDOMAIN, URL, host, brand,
       LAG(host)          OVER w                                 AS prev_host,
       LAG(URL)           OVER w                                 AS prev_url,
       LAG(SESSION_ID)    OVER w                                 AS prev_session,
       DATE_DIFF('millisecond', LAG(CREATED_TIME) OVER w, CREATED_TIME) AS gap_ms,
       LEAD(host)         OVER w                                 AS next_host,
       LEAD(URL)          OVER w                                 AS next_url
FROM stg_events
WHERE is_brand_user
WINDOW w AS (PARTITION BY USER_ID ORDER BY CREATED_TIME, _ID);


-- name: scope
-- How many rows and users the filter kept.
SELECT (SELECT COUNT(*) FROM brand_users)                         AS n_brand_users,
       (SELECT COUNT(*) FROM bu_events)                           AS n_events_kept,
       (SELECT COUNT(*) FROM bu_events WHERE brand IS NOT NULL)   AS n_brand_site_events;


-- name: brand_hosts
-- Hosts with a brand name: main site, other subdomains, non-US.
SELECT REGEXP_EXTRACT(host, '(saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart)', 1) AS brand_token,
       host,
       COUNT(*)                AS n_events,
       COUNT(DISTINCT USER_ID) AS n_users
FROM bu_events
WHERE REGEXP_MATCHES(host, 'saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart')
GROUP BY ALL
ORDER BY brand_token, n_events DESC, host;


-- name: param_keys_by_brand
-- Query-parameter keys on brand-site URLs, by number of users.
WITH kv AS (
    SELECT brand, USER_ID, URL,
           UNNEST(STRING_SPLIT(REGEXP_EXTRACT(URL, '\?([^#]*)', 1), '&')) AS pair
    FROM bu_events
    WHERE brand IS NOT NULL
),
k AS (
    SELECT brand, USER_ID, URL, LOWER(SPLIT_PART(pair, '=', 1)) AS param_key
    FROM kv WHERE pair <> ''
)
SELECT brand,
       param_key,
       COUNT(*)                AS n_rows,
       COUNT(DISTINCT USER_ID) AS n_users,
       MIN(URL)          AS example_url
FROM k
GROUP BY brand, param_key
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand ORDER BY COUNT(DISTINCT USER_ID) DESC, param_key) <= 60
ORDER BY brand, n_users DESC, param_key;


-- name: entry_prev_hosts
-- Host of the page just before entering a brand site (networks, publishers, search).
SELECT brand,
       prev_host,
       COUNT(*)                         AS n_entries,
       COUNT(DISTINCT USER_ID)          AS n_users,
       QUANTILE_CONT(gap_ms, 0.5)       AS median_gap_ms,
       MIN(prev_url)              AS example_prev_url,
       MIN(URL)                   AS example_landing_url
FROM bu_events
WHERE brand IS NOT NULL
  AND prev_host IS DISTINCT FROM host
GROUP BY brand, prev_host
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand ORDER BY COUNT(*) DESC, prev_host) <= 40
ORDER BY brand, n_entries DESC, prev_host;


-- name: network_next_hosts
-- Network / redirect hosts (seed list + click/track/redirect in the name) and where they lead.
SELECT host        AS network_host,
       next_host,
       COUNT(*)                AS n,
       COUNT(DISTINCT USER_ID) AS n_users,
       MIN(URL)          AS example_url,
       MIN(next_url)     AS example_next_url
FROM bu_events
WHERE REGEXP_MATCHES(host,
        'prf\.hn|sjv\.io|pxf\.io|7eer\.net|impact|^imp\.|anrdoezrs|jdoqocy|tkqlhce|dpbolvw|kqzyfj'
     || '|linksynergy|awin1|shareasale|skimresources|viglink|sovrn|howl\.me|avantlink|goto\.walmart'
     || '|click|track|redirect|redir|go\.|link\.')
  AND REGEXP_MATCHES(COALESCE(next_host, ''), 'saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart')
GROUP BY ALL
ORDER BY n DESC, network_host, next_host
LIMIT 100;

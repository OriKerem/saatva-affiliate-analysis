-- 02_param_values.sql
-- Follow-up checks after step 01: parameter values (wmlspartner=imp_... is affiliate,
-- wmlspartner=wlpa is a Google ad), full presence of the seed parameters and redirect domains,
-- and whether search-result pages exist in the data.
-- Needs stg_events and bu_events from the same run mode.


-- name: build_brand_params
-- One row per brand-site event and parameter. Values cut to a short prefix (no full IDs).
CREATE OR REPLACE TABLE brand_params AS
WITH kv AS (
    SELECT brand, USER_ID, _ID,
           UNNEST(STRING_SPLIT(REGEXP_EXTRACT(URL, '\?([^#]*)', 1), '&')) AS pair
    FROM bu_events
    WHERE brand IS NOT NULL
)
SELECT brand, USER_ID, _ID,
       LOWER(SPLIT_PART(pair, '=', 1))                    AS param_key,
       LOWER(SPLIT_PART(pair, '=', 2))                     AS param_value
FROM kv
WHERE pair <> '';


-- name: decisive_param_values
-- Values of the parameters that decide affiliate or not. Long IDs grouped by prefix.
WITH v AS (
    SELECT brand, param_key,
           CASE
               WHEN param_key IN ('wmlspartner', 'sourceid')
                    THEN REGEXP_EXTRACT(param_value, '^([a-z]+_?)', 1) || '…'
               WHEN param_key IN ('click_id', 'app_clickref', 'clickref')  -- Partnerize: prefix is meaningful
                    THEN LEFT(param_value, 5) || '…'
               WHEN param_key IN ('irclickid', 'clickid', 'cidimp', 'sharedid')
                    THEN '<id present>'
               ELSE LEFT(param_value, 40)
           END AS value_pattern,
           USER_ID
    FROM brand_params
    WHERE param_key IN ('utm_medium', 'utm_source', 'utm_campaign', 'veh', 'wmlspartner', 'sourceid',
                        'afsrc', 'irgwc', 'click_id', 'app_clickref', 'irclickid', 'clickid',
                        'cidimp', 'coupon', 'clickref')
)
SELECT brand, param_key, value_pattern,
       COUNT(*)                AS n_rows,
       COUNT(DISTINCT USER_ID) AS n_users
FROM v
GROUP BY brand, param_key, value_pattern
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand, param_key ORDER BY COUNT(DISTINCT USER_ID) DESC, value_pattern) <= 15
ORDER BY brand, param_key, n_users DESC, value_pattern;


-- name: seed_param_presence
-- Every seed parameter per brand, no top-N cap. 0 users = not used on that site.
WITH seeds(param_key) AS (
    VALUES ('irclickid'), ('irgwc'), ('im_ref'), ('sharedid'), ('clickid'), ('cjevent'), ('cjdata'),
           ('ranmid'), ('raneaid'), ('ransiteid'), ('awc'), ('sscid'), ('sas'), ('clickref'),
           ('camref'), ('aff_id'), ('affid'), ('ref'), ('veh'), ('sourceid'), ('utm_medium'),
           ('click_id'), ('app_clickref'), ('cidimp'), ('afsrc'), ('wmlspartner'), ('affiliates_ad_id'),
           ('gclid'), ('msclkid'), ('gad_source'), ('fbclid')
),
brands(brand) AS (VALUES ('saatva'), ('nectar'), ('helix'), ('dreamcloud'), ('walmart'))
SELECT b.brand, s.param_key,
       COUNT(DISTINCT p.USER_ID) AS n_users
FROM brands b
CROSS JOIN seeds s
LEFT JOIN brand_params p ON p.brand = b.brand AND p.param_key = s.param_key
GROUP BY b.brand, s.param_key
ORDER BY b.brand, n_users DESC, s.param_key;


-- name: seed_domain_presence
-- Seed redirect domains anywhere in brand users' journeys, and the brand site visited next.
WITH seeds(pattern, network) AS (
    VALUES ('prf\.hn$', 'Partnerize'), ('sjv\.io$', 'Impact'), ('pxf\.io$', 'Impact'),
           ('7eer\.net$', 'Impact'), ('impact(cdn|radius)', 'Impact'),
           ('anrdoezrs\.net$|jdoqocy\.com$|tkqlhce\.com$|dpbolvw\.net$|kqzyfj\.com$', 'CJ'),
           ('linksynergy\.com$', 'Rakuten'), ('awin1\.com$', 'Awin'), ('shareasale\.com$', 'ShareASale'),
           ('skimresources\.com$', 'Skimlinks'), ('viglink\.com$|sovrn\.(com|co)$', 'Sovrn/VigLink'),
           ('howl\.me$', 'Howl'), ('avantlink\.com$', 'AvantLink'), ('goto\.walmart\.com$', 'Walmart/Impact')
),
-- Match the patterns on distinct hosts (thousands) and join back, not on every event.
matched AS (
    SELECT DISTINCT h.host, s.network
    FROM (SELECT DISTINCT host FROM bu_events) h
    JOIN seeds s ON REGEXP_MATCHES(h.host, s.pattern)
)
SELECT m.network,
       e.host,
       COALESCE(e.next_host, '(end)')  AS next_host,
       COUNT(*)                        AS n_events,
       COUNT(DISTINCT e.USER_ID)       AS n_users
FROM matched m
JOIN bu_events e ON e.host = m.host
GROUP BY ALL
ORDER BY m.network, n_events DESC, e.host, next_host;


-- name: search_engine_presence
-- Are search-result pages in the panel at all? Counted on the whole data.
-- Other Google pages (mail, docs, maps) are kept apart from search.
SELECT search_page              AS page_type,
       COUNT(*)                 AS n_events,
       COUNT(DISTINCT USER_ID)  AS n_users
FROM stg_events
WHERE search_page IS NOT NULL
GROUP BY 1
ORDER BY n_events DESC, page_type;


-- name: search_engine_hosts
-- Search-engine hosts present in the data.
SELECT host, COUNT(*) AS n_events, COUNT(DISTINCT USER_ID) AS n_users
FROM stg_events
WHERE REGEXP_MATCHES(host, '(^|\.)(google\.[a-z]{2,3}(\.[a-z]{2})?|(bing|duckduckgo|yahoo)\.com)$')
GROUP BY 1
ORDER BY n_events DESC, host
LIMIT 40;

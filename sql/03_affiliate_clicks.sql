-- 03_affiliate_clicks.sql
-- Affiliate clicks per brand, with publisher. Needs bu_events (step 01).
--
-- Affiliate landing = brand-site URL with one of (same rules for every brand):
--   utm_medium=affiliate|aff                    channel tag
--   click_id / app_clickref / clickref           Partnerize
--   irgwc=1 / irclickid / cidimp                 Impact
--   veh=aff / wmlspartner=imp_... / sourceid=imp_... / affiliates_ad_id    Walmart (Impact)
-- Not enough on their own: afsrc, coupon, paid-search markers (gclid, gad_source, msclkid, ...).
--
-- Click = user x brand x publisher; landings < 30 min apart are merged. Another publisher's landing
-- starts a new click (needed for the fraud step). 10 / 60 min reported as a check.
-- Publisher = wmlspartner=imp_..., else ir_partnerid, else utm_source.
--
-- Panel duplicates (same person under several USER_IDs) are flagged, not deleted:
--   rule 1: same brand + per-click ID + second under another USER_ID (Partnerize / Impact IDs;
--           Walmart's clickid is shared by many people, so it is not used)
--   rule 2: same brand + person (person_map) + second under another USER_ID
-- Later steps use NOT is_panel_duplicate.


-- name: build_affiliate_landings
CREATE OR REPLACE TABLE affiliate_landings AS
WITH b AS (
    SELECT USER_ID, SESSION_ID, _ID, CREATED_TIME, brand, URL, prev_host, prev_url, next_host, gap_ms,
           -- '&k=v&' form, lower-case, so each marker matches a whole parameter
           '&' || LOWER(COALESCE(REGEXP_EXTRACT(URL, '\?([^#]*)', 1), '')) || '&' AS qs
    FROM bu_events
    WHERE brand IS NOT NULL
),
m AS (
    SELECT *,
           REGEXP_MATCHES(qs, '&utm_medium=(affiliate|aff)&')                                     AS m_utm_affiliate,
           REGEXP_MATCHES(qs, '&(click_id|app_clickref|clickref)=[^&]')                            AS m_partnerize,
           REGEXP_MATCHES(qs, '&(irgwc=1|irclickid=[^&]|cidimp=[^&])')                             AS m_impact,
           REGEXP_MATCHES(qs, '&(veh=aff&|wmlspartner(_creator)?=imp_|sourceid=imp_|affiliates_ad_id(_creator)?=[^&])') AS m_walmart_aff,
           REGEXP_MATCHES(qs, '&(gclid|gad_source|gbraid|wbraid|msclkid)=[^&]|&veh=sem')           AS m_paid_search,
           REGEXP_MATCHES(qs, '&afsrc=1&')                                                        AS m_afsrc,
           COALESCE(NULLIF(REGEXP_EXTRACT(qs, '&wmlspartner(_creator)?=(imp_[^&]+)', 2), ''),
                    'ir:' || NULLIF(REGEXP_EXTRACT(qs, '&ir_partnerid=([^&]+)', 1), ''),
                    'src:' || NULLIF(REGEXP_EXTRACT(qs, '&utm_source=([^&]+)', 1), ''))            AS publisher_id,
           -- per-click network ID (Walmart's clickid left out on purpose)
           NULLIF(REGEXP_EXTRACT(qs, '&(click_id|app_clickref|clickref|irclickid|cidimp)=([^&]+)', 2), '') AS click_ref
    FROM b
)
SELECT USER_ID, SESSION_ID, _ID, CREATED_TIME, brand, URL, prev_host, prev_url, next_host, gap_ms,
       m_utm_affiliate, m_partnerize, m_impact, m_walmart_aff, m_paid_search, m_afsrc,
       COALESCE(publisher_id, '(unknown)') AS publisher_id,
       click_ref
FROM m
WHERE m_utm_affiliate OR m_partnerize OR m_impact OR m_walmart_aff;


-- name: build_person_map
-- One row per USER_ID with a person_id.
-- Fingerprint of the day = count of distinct (second, host) events + XOR of their hashes.
-- IDs with >= 10 events and the same fingerprint are one person (person_id = smallest USER_ID).
-- Exact copies only, so this is a lower bound.
CREATE OR REPLACE TABLE person_map AS
WITH ev AS (
    SELECT DISTINCT USER_ID, CREATED_TIME, host FROM stg_events
),
fp AS (
    SELECT USER_ID, COUNT(*) AS n_events, BIT_XOR(hash(CREATED_TIME, host)) AS fingerprint
    FROM ev
    GROUP BY USER_ID
)
SELECT USER_ID, n_events, fingerprint,
       CASE WHEN n_events >= 10
            THEN MIN(USER_ID) OVER (PARTITION BY n_events, fingerprint)
            ELSE USER_ID END AS person_id
FROM fp;


-- name: build_affiliate_clicks
-- Landings to clicks (30-min merge per user x brand x publisher), then flag panel duplicates.
CREATE OR REPLACE TABLE affiliate_clicks AS
WITH o AS (
    SELECT *,
           LAG(CREATED_TIME) OVER w AS prev_landing_time,
           LAG(publisher_id) OVER w AS prev_landing_publisher
    FROM affiliate_landings
    WINDOW w AS (PARTITION BY USER_ID, brand ORDER BY CREATED_TIME, _ID)
),
f AS (
    SELECT *,
           CASE WHEN prev_landing_time IS NULL
                  OR DATE_DIFF('second', prev_landing_time, CREATED_TIME) > 30 * 60
                  OR publisher_id IS DISTINCT FROM prev_landing_publisher
                THEN 1 ELSE 0 END AS is_new_click
    FROM o
),
c AS (
    SELECT *,
           SUM(is_new_click) OVER (PARTITION BY USER_ID, brand ORDER BY CREATED_TIME, _ID
                                   ROWS UNBOUNDED PRECEDING) AS click_seq
    FROM f
)
SELECT per_user.*,
       pm.person_id,
       -- rule 1: same per-click ID in the same second.
       -- DENSE_RANK on USER_ID: only clicks under another USER_ID are flagged, never a user's own clicks.
       (click_ref IS NOT NULL
        AND DENSE_RANK() OVER (PARTITION BY brand, click_ref, click_time ORDER BY per_user.USER_ID) > 1)
       -- rule 2: same person in the same second (Walmart has no per-click ID)
       OR DENSE_RANK() OVER (PARTITION BY brand, pm.person_id, click_time ORDER BY per_user.USER_ID) > 1
                                                           AS is_panel_duplicate
FROM (
SELECT brand,
       USER_ID,
       click_seq,
       MIN(CREATED_TIME)                                   AS click_time,
       ARG_MIN(SESSION_ID, CREATED_TIME)                   AS SESSION_ID,
       MIN(publisher_id)                                   AS publisher_id,     -- constant within a click
       ARG_MIN(prev_host, CREATED_TIME)                    AS entry_prev_host,  -- page seen just before
       ARG_MIN(URL, CREATED_TIME)                          AS landing_url,
       COUNT(*)                                            AS n_landing_events,
       BOOL_OR(m_utm_affiliate)                            AS m_utm_affiliate,
       BOOL_OR(m_partnerize)                               AS m_partnerize,
       BOOL_OR(m_impact)                                   AS m_impact,
       BOOL_OR(m_walmart_aff)                              AS m_walmart_aff,
       BOOL_OR(m_paid_search)                              AS m_paid_search,    -- for the fraud step
       BOOL_OR(m_afsrc)                                    AS m_afsrc,
       ARG_MIN(click_ref, CREATED_TIME)                    AS click_ref         -- ID on the first landing
FROM c
GROUP BY brand, USER_ID, click_seq
) per_user
JOIN person_map pm USING (USER_ID);


-- name: clicks_by_brand
-- Counts per brand in the panel. n_clicks_dedup (after duplicates) is used from here on.
SELECT l.brand,
       l.n_landing_events,
       c.n_clicks,
       c.n_panel_duplicates,
       c.n_clicks_dedup,
       c.n_users,
       c.n_publishers,
       c.n_clicks_with_paid_search_marker,
       c.n_clicks_with_afsrc
FROM (SELECT brand, COUNT(*) AS n_landing_events FROM affiliate_landings GROUP BY brand) l
JOIN (SELECT brand,
             COUNT(*)                                            AS n_clicks,
             SUM(CASE WHEN is_panel_duplicate THEN 1 ELSE 0 END) AS n_panel_duplicates,
             SUM(CASE WHEN is_panel_duplicate THEN 0 ELSE 1 END) AS n_clicks_dedup,
             COUNT(DISTINCT USER_ID)                             AS n_users,
             COUNT(DISTINCT publisher_id)                        AS n_publishers,
             SUM(CASE WHEN m_paid_search THEN 1 ELSE 0 END)      AS n_clicks_with_paid_search_marker,
             SUM(CASE WHEN m_afsrc THEN 1 ELSE 0 END)            AS n_clicks_with_afsrc
      FROM affiliate_clicks GROUP BY brand) c USING (brand)
ORDER BY c.n_clicks DESC, l.brand;


-- name: marker_overlap
-- Which markers identified each click. Several agreeing = robust rule.
SELECT brand,
       m_utm_affiliate, m_partnerize, m_impact, m_walmart_aff,
       COUNT(*) AS n_clicks
FROM affiliate_clicks
GROUP BY ALL
ORDER BY brand, n_clicks DESC, m_utm_affiliate, m_partnerize, m_impact, m_walmart_aff;


-- name: dedup_sanity
-- The duplicate rules must never drop every copy of a click. Expected: 0 rows.
SELECT brand, click_time, publisher_id, COUNT(*) AS n_copies
FROM affiliate_clicks
GROUP BY brand, click_time, publisher_id
HAVING COUNT(*) > 1 AND BOOL_AND(is_panel_duplicate)
ORDER BY brand, click_time
LIMIT 50;


-- name: clicks_window_sensitivity
-- Click counts with a 10 / 30 / 60 minute merge window.
WITH o AS (
    SELECT brand, USER_ID, publisher_id, CREATED_TIME,
           DATE_DIFF('second',
                     LAG(CREATED_TIME) OVER (PARTITION BY USER_ID, brand ORDER BY CREATED_TIME, _ID),
                     CREATED_TIME) AS gap_s,
           LAG(publisher_id) OVER (PARTITION BY USER_ID, brand ORDER BY CREATED_TIME, _ID) AS prev_pub
    FROM affiliate_landings
)
SELECT brand,
       COUNT(*)                                                                               AS no_dedup,
       SUM(CASE WHEN gap_s IS NULL OR gap_s > 10*60 OR publisher_id IS DISTINCT FROM prev_pub THEN 1 ELSE 0 END) AS window_10_min,
       SUM(CASE WHEN gap_s IS NULL OR gap_s > 30*60 OR publisher_id IS DISTINCT FROM prev_pub THEN 1 ELSE 0 END) AS window_30_min,
       SUM(CASE WHEN gap_s IS NULL OR gap_s > 60*60 OR publisher_id IS DISTINCT FROM prev_pub THEN 1 ELSE 0 END) AS window_60_min
FROM o
GROUP BY brand
ORDER BY brand;


-- name: top_publishers
-- Top 15 publishers per brand.
SELECT brand, publisher_id,
       COUNT(*)                AS n_clicks,
       COUNT(DISTINCT USER_ID) AS n_users,
       MIN(entry_prev_host)    AS example_prev_host
FROM affiliate_clicks
GROUP BY brand, publisher_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand ORDER BY COUNT(*) DESC, publisher_id) <= 15
ORDER BY brand, n_clicks DESC, publisher_id;


-- name: click_examples
-- 10 example clicks per brand for a manual check (earliest first). Full URLs: not committed.
SELECT brand, click_time, publisher_id, entry_prev_host, n_landing_events,
       m_utm_affiliate, m_partnerize, m_impact, m_walmart_aff, m_paid_search, m_afsrc,
       landing_url
FROM affiliate_clicks
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand ORDER BY click_time, USER_ID) <= 10
ORDER BY brand, click_time;


-- name: shared_click_ids
-- Click IDs seen under more than one USER_ID in the same second (should not happen).
WITH ids AS (
    SELECT brand, USER_ID, CREATED_TIME,
           REGEXP_EXTRACT(LOWER(URL), '[?&](click_id|app_clickref|clickref|irclickid|cidimp|clickid)=([^&]+)', 2) AS click_ref
    FROM affiliate_landings
)
SELECT brand,
       LEFT(click_ref, 6) || '...'               AS click_ref_prefix,   -- not the full ID (privacy)
       COUNT(DISTINCT USER_ID)                 AS n_users,
       COUNT(*)                                AS n_landings,
       MIN(CREATED_TIME)                       AS first_seen,
       DATE_DIFF('second', MIN(CREATED_TIME), MAX(CREATED_TIME)) AS spread_s
FROM ids
WHERE click_ref <> ''
GROUP BY brand, click_ref
HAVING COUNT(DISTINCT USER_ID) > 1
ORDER BY n_users DESC, brand, first_seen
LIMIT 100;


-- name: build_shared_click_pairs
-- For each pair of IDs sharing a click ID: share of the day that is identical (same second + host).
-- ~100% = same person logged twice; low = different people.
CREATE OR REPLACE TABLE shared_click_pairs AS
WITH ids AS (
    SELECT DISTINCT brand, USER_ID,
           REGEXP_EXTRACT(LOWER(URL), '[?&](click_id|app_clickref|clickref|irclickid|cidimp|clickid)=([^&]+)', 2) AS click_ref
    FROM affiliate_landings
),
pairs AS (
    SELECT DISTINCT a.brand, a.click_ref, a.USER_ID AS u1, b.USER_ID AS u2
    FROM ids a JOIN ids b ON a.click_ref = b.click_ref AND a.USER_ID < b.USER_ID
    WHERE a.click_ref <> ''
),
ev AS (
    SELECT DISTINCT USER_ID, CREATED_TIME, host
    FROM bu_events
    WHERE USER_ID IN (SELECT u1 FROM pairs UNION SELECT u2 FROM pairs)
),
n AS (SELECT USER_ID, COUNT(*) AS n_events FROM ev GROUP BY USER_ID),
shared AS (
    SELECT p.brand, p.click_ref, p.u1, p.u2, COUNT(e2.USER_ID) AS n_shared
    FROM pairs p
    JOIN ev e1 ON e1.USER_ID = p.u1
    LEFT JOIN ev e2 ON e2.USER_ID = p.u2 AND e2.CREATED_TIME = e1.CREATED_TIME AND e2.host = e1.host
    GROUP BY ALL
)
SELECT s.brand, s.click_ref,
       n1.n_events                                         AS events_user_1,
       n2.n_events                                         AS events_user_2,
       s.n_shared                                          AS identical_events,
       ROUND(100.0 * s.n_shared / LEAST(n1.n_events, n2.n_events), 1) AS pct_identical_of_smaller
FROM shared s
JOIN n n1 ON n1.USER_ID = s.u1
JOIN n n2 ON n2.USER_ID = s.u2;


-- name: shared_click_journey_overlap
-- One row per pair (click ID cut to 6 characters).
SELECT brand,
       LEFT(click_ref, 6) || '...'  AS click_ref_prefix,
       events_user_1, events_user_2, identical_events, pct_identical_of_smaller
FROM shared_click_pairs
ORDER BY brand, pct_identical_of_smaller DESC, click_ref_prefix, events_user_1, events_user_2
LIMIT 100;


-- name: shared_click_overlap_summary
-- Pairs per overlap bucket; "same person" at 50 / 90 / 100% (each also needs >= 10 identical events).
SELECT brand,
       COUNT(*)                                                                         AS n_pairs,
       SUM(CASE WHEN pct_identical_of_smaller < 20 THEN 1 ELSE 0 END)                   AS pct_0_20,
       SUM(CASE WHEN pct_identical_of_smaller >= 20 AND pct_identical_of_smaller < 50 THEN 1 ELSE 0 END) AS pct_20_50,
       SUM(CASE WHEN pct_identical_of_smaller >= 50 AND pct_identical_of_smaller < 90 THEN 1 ELSE 0 END) AS pct_50_90,
       SUM(CASE WHEN pct_identical_of_smaller >= 90 THEN 1 ELSE 0 END)                  AS pct_90_100,
       SUM(CASE WHEN pct_identical_of_smaller >= 50  AND identical_events >= 10 THEN 1 ELSE 0 END) AS same_person_at_50,
       SUM(CASE WHEN pct_identical_of_smaller >= 90  AND identical_events >= 10 THEN 1 ELSE 0 END) AS same_person_at_90,
       SUM(CASE WHEN pct_identical_of_smaller >= 100 AND identical_events >= 10 THEN 1 ELSE 0 END) AS same_person_at_100
FROM shared_click_pairs
GROUP BY brand
ORDER BY brand;


-- name: panel_duplicate_users
-- Duplicate people in the whole panel (from person_map; exact copies, so a lower bound).
-- Only meaningful on the full data: a user sample sees a pair only if both IDs are drawn.
WITH grp AS (
    SELECT person_id, COUNT(*) AS n_ids
    FROM person_map
    GROUP BY person_id
)
SELECT (SELECT COUNT(*) FROM person_map)                           AS n_user_ids,
       (SELECT COUNT(*) FROM person_map WHERE n_events >= 10)      AS n_user_ids_10plus_events,
       COUNT(*)                                                    AS n_people,
       SUM(CASE WHEN n_ids > 1 THEN 1 ELSE 0 END)                  AS n_duplicate_groups,
       SUM(CASE WHEN n_ids > 1 THEN n_ids ELSE 0 END)              AS n_ids_in_groups,
       SUM(n_ids - 1)                                              AS n_redundant_ids,
       ROUND(100.0 * SUM(n_ids - 1) / SUM(n_ids), 3)               AS pct_redundant_of_all_ids,
       MAX(n_ids)                                                  AS max_ids_per_person
FROM grp;

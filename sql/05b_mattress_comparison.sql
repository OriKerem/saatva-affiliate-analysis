-- 05b_mattress_comparison.sql
-- Walmart sells everything, so it is compared through its mattress section only.
-- Needs bu_events, person_map, affiliate_clicks, conversion_events, click_conversions; runs after 05.
--
-- Mattress page = product, search, category, brand or sponsored page on walmart.com whose URL contains
-- "mattress" (accessories such as toppers kept; orders, help and account pages not).
-- walmart_mattress visitors = people who viewed such a page; clicks = Walmart affiliate clicks whose
-- session included one. The confirmation page does not name the product, so conversions are those
-- credited to a mattress-session click.
-- Ranges by person: bootstrap for > 10 people, Garwood for <= 10; Clopper-Pearson when 0 conversions.


-- name: build_walmart_mattress_pages
CREATE OR REPLACE TABLE walmart_mattress_pages AS
SELECT b.USER_ID, b.SESSION_ID, b.CREATED_TIME, pm.person_id,
       REGEXP_EXTRACT(LOWER(b.URL), '^[a-z]+://[^/?#]+/([a-z]+)', 1) AS page_type
FROM bu_events b
JOIN person_map pm USING (USER_ID)
WHERE b.host = 'walmart.com'
  AND LOWER(b.URL) LIKE '%mattress%'
  AND REGEXP_EXTRACT(LOWER(b.URL), '^[a-z]+://[^/?#]+/([a-z]+)', 1) IN ('ip', 'search', 'browse', 'cp', 'brand', 'sp');


-- name: walmart_mattress_page_types
-- Mattress pages by page type (check of the definition).
SELECT page_type, COUNT(*) AS n_events, COUNT(DISTINCT person_id) AS n_people
FROM walmart_mattress_pages
GROUP BY page_type
ORDER BY n_people DESC, page_type;


-- name: build_segment_clicks
-- Affiliate clicks with their segment. Walmart clicks count in walmart_all, and also in
-- walmart_mattress when their session had a mattress page.
CREATE OR REPLACE TABLE segment_clicks AS
WITH k AS (
    SELECT brand, person_id, USER_ID, SESSION_ID, click_time
    FROM affiliate_clicks
    WHERE NOT is_panel_duplicate
),
conv AS (   -- the click that got the last-click credit, and for what
    SELECT brand, person_id, credited_click_time,
           MAX(CASE WHEN tier IN ('purchase', 'registration') THEN 1 ELSE 0 END) AS converted
    FROM click_conversions
    GROUP BY brand, person_id, credited_click_time
),
kc AS (
    SELECT k.*, COALESCE(c.converted, 0) AS converted
    FROM k LEFT JOIN conv c
      ON c.brand = k.brand AND c.person_id = k.person_id AND c.credited_click_time = k.click_time
)
SELECT CASE WHEN brand = 'walmart' THEN 'walmart_all' ELSE brand END AS segment, person_id, click_time, converted
FROM kc
UNION ALL
SELECT 'walmart_mattress', kc.person_id, kc.click_time, kc.converted
FROM kc
WHERE kc.brand = 'walmart'
  AND EXISTS (SELECT 1 FROM walmart_mattress_pages m
              WHERE m.USER_ID = kc.USER_ID AND m.SESSION_ID = kc.SESSION_ID);


-- name: build_segment_bootstrap
CREATE OR REPLACE TABLE segment_bootstrap AS
WITH pp AS (
    SELECT segment, person_id, COUNT(*) AS n_clicks, SUM(converted) AS converted
    FROM segment_clicks GROUP BY segment, person_id
),
w AS (
    SELECT r.range AS rep, pp.segment, pp.n_clicks, pp.converted,
           (hash(pp.person_id, r.range) % 1000000000) / 1e9 AS u
    FROM pp CROSS JOIN range(1, 1001) r
)
SELECT rep, segment,
       SUM(n_clicks * CASE WHEN u < 0.367879 THEN 0 WHEN u < 0.735759 THEN 1 WHEN u < 0.919699 THEN 2
                           WHEN u < 0.981012 THEN 3 WHEN u < 0.996340 THEN 4 WHEN u < 0.999406 THEN 5
                           WHEN u < 0.999917 THEN 6 ELSE 7 END) AS clicks
FROM w
GROUP BY rep, segment;


-- name: mattress_comparison
-- One row per segment: visitors, purchases (any channel), affiliate clicks, credited conversions,
-- US clicks per day with 95% range, conversion rate (or upper bound when 0).
WITH f AS (SELECT 322000000::DOUBLE / (SELECT COUNT(DISTINCT person_id) FROM person_map) AS factor),
garwood(k, lo, hi) AS (
    VALUES (0, 0.000, 3.689), (1, 0.025, 5.572), (2, 0.242, 7.225), (3, 0.619, 8.767),
           (4, 1.090, 10.242), (5, 1.623, 11.668), (6, 2.202, 13.059), (7, 2.814, 14.423),
           (8, 3.454, 15.763), (9, 4.115, 17.085), (10, 4.795, 18.390)
),
visitors AS (
    SELECT b.brand AS segment, pm.person_id
    FROM bu_events b JOIN person_map pm USING (USER_ID)
    WHERE b.brand IS NOT NULL
    GROUP BY ALL
),
v AS (
    SELECT CASE WHEN segment = 'walmart' THEN 'walmart_all' ELSE segment END AS segment, person_id FROM visitors
    UNION ALL
    SELECT DISTINCT 'walmart_mattress', person_id FROM walmart_mattress_pages
),
buy AS (
    SELECT DISTINCT CASE WHEN brand = 'walmart' THEN 'walmart_all' ELSE brand END AS segment, person_id
    FROM conversion_events WHERE tier = 'purchase'
    UNION ALL
    SELECT DISTINCT 'walmart_mattress', person_id
    FROM conversion_events WHERE brand = 'walmart' AND tier = 'purchase'
),
vs AS (
    SELECT v.segment, COUNT(DISTINCT v.person_id) AS site_visitors,
           COUNT(DISTINCT b.person_id)            AS visitors_who_purchased
    FROM v LEFT JOIN buy b ON b.segment = v.segment AND b.person_id = v.person_id
    GROUP BY v.segment
),
cs AS (
    SELECT segment, COUNT(*) AS affiliate_clicks, COUNT(DISTINCT person_id) AS people_clicked,
           SUM(converted) AS clicks_converted,
           COUNT(DISTINCT CASE WHEN converted = 1 THEN person_id END) AS people_converted
    FROM segment_clicks GROUP BY segment
),
bs AS (
    SELECT segment, QUANTILE_CONT(clicks, 0.025) AS b_lo, QUANTILE_CONT(clicks, 0.975) AS b_hi
    FROM segment_bootstrap GROUP BY segment
),
r AS (
    SELECT vs.*, COALESCE(cs.affiliate_clicks, 0) AS affiliate_clicks,
           COALESCE(cs.people_clicked, 0) AS people_clicked,
           COALESCE(cs.clicks_converted, 0) AS clicks_converted,
           COALESCE(cs.people_converted, 0) AS people_converted,
           CASE WHEN cs.people_clicked <= 10 THEN g.lo * cs.affiliate_clicks / cs.people_clicked ELSE bs.b_lo END AS lo,
           CASE WHEN cs.people_clicked <= 10 THEN g.hi * cs.affiliate_clicks / cs.people_clicked ELSE bs.b_hi END AS hi
    FROM vs LEFT JOIN cs USING (segment)
    LEFT JOIN bs USING (segment)
    LEFT JOIN garwood g ON g.k = cs.people_clicked
)
SELECT r.segment,
       r.site_visitors,
       r.visitors_who_purchased,
       r.affiliate_clicks,
       r.people_clicked,
       r.clicks_converted,
       ROUND(r.affiliate_clicks * f.factor) AS us_clicks_per_day,
       ROUND(r.lo * f.factor)               AS us_clicks_lo,
       ROUND(r.hi * f.factor)               AS us_clicks_hi,
       CASE WHEN r.clicks_converted > 0
            THEN ROUND(100.0 * r.clicks_converted / r.affiliate_clicks, 2) END              AS conversion_rate_pct,
       CASE WHEN r.affiliate_clicks > 0 AND r.clicks_converted = 0
            THEN ROUND(100.0 * (1 - POW(0.025, 1.0 / r.people_clicked)), 1) END            AS people_converted_upper_bound_pct
FROM r CROSS JOIN f
ORDER BY CASE r.segment WHEN 'saatva' THEN 1 WHEN 'nectar' THEN 2 WHEN 'helix' THEN 3 WHEN 'dreamcloud' THEN 4
                        WHEN 'walmart_mattress' THEN 5 ELSE 6 END;

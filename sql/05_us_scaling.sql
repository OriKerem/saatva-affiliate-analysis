-- 05_us_scaling.sql
-- Panel counts to US estimates, with 95% ranges.
-- Needs person_map, affiliate_clicks (step 03) and click_conversions (step 04).
--
-- Scale factor = 322 M US internet users (DataReportal, Digital 2025) / panel people (person_map).
-- Assumes the panel represents US internet users (no weights in the data).
--
-- Ranges: person-level Poisson bootstrap, 1,000 replicates. People are resampled, not rows, because
-- one person's clicks are correlated. Weights come from hash(person, replicate): same result every run.
-- DTC brands (2-4 clicks, 0 conversions): a bootstrap of 0 gives [0, 0], so exact intervals are used:
-- Garwood for clicks, Clopper-Pearson 1 - 0.025^(1/n) for 0 conversions out of n people.


-- name: build_person_brand
-- One row per brand and person who clicked: clicks and credited conversions.
CREATE OR REPLACE TABLE person_brand AS
WITH k AS (
    SELECT brand, person_id, COUNT(*) AS n_clicks
    FROM affiliate_clicks
    WHERE NOT is_panel_duplicate
    GROUP BY brand, person_id
),
c AS (
    SELECT brand, person_id,
           MAX(CASE WHEN tier IN ('purchase', 'registration') THEN 1 ELSE 0 END) AS converted,
           MAX(CASE WHEN tier = 'purchase' THEN 1 ELSE 0 END)                    AS purchased
    FROM click_conversions
    GROUP BY brand, person_id
)
SELECT k.brand, k.person_id, k.n_clicks,
       COALESCE(c.converted, 0) AS converted,
       COALESCE(c.purchased, 0) AS purchased
FROM k LEFT JOIN c USING (brand, person_id);


-- name: scaling_factor
WITH params AS (SELECT 322000000::DOUBLE AS us_internet_users)
SELECT p.us_internet_users,
       (SELECT COUNT(DISTINCT person_id) FROM person_map) AS panel_people,
       (SELECT COUNT(*) FROM person_map)                  AS panel_user_ids,
       ROUND(p.us_internet_users / (SELECT COUNT(DISTINCT person_id) FROM person_map), 1) AS scale_factor,
       ROUND(p.us_internet_users / (SELECT COUNT(*) FROM person_map), 1)                  AS scale_factor_if_ids_were_people
FROM params p;


-- name: build_bootstrap
-- 1,000 replicates x people who clicked. Poisson(1) weight from u = hash(person, replicate) / 10^9.
CREATE OR REPLACE TABLE bootstrap_reps AS
WITH reps AS (SELECT range AS rep FROM range(1, 1001)),
w AS (
    SELECT r.rep, pb.brand, pb.n_clicks, pb.converted, pb.purchased,
           (hash(pb.person_id, r.rep) % 1000000000) / 1e9 AS u
    FROM person_brand pb CROSS JOIN reps r
),
pw AS (
    SELECT *,
           CASE WHEN u < 0.367879 THEN 0 WHEN u < 0.735759 THEN 1 WHEN u < 0.919699 THEN 2
                WHEN u < 0.981012 THEN 3 WHEN u < 0.996340 THEN 4 WHEN u < 0.999406 THEN 5
                WHEN u < 0.999917 THEN 6 ELSE 7 END AS weight
    FROM w
)
SELECT rep, brand,
       SUM(weight * n_clicks)  AS clicks,
       SUM(weight * converted) AS converted,
       SUM(weight * purchased) AS purchased,
       SUM(weight)             AS people
FROM pw
GROUP BY rep, brand;


-- name: us_estimates
-- Panel x factor, and 2.5th / 97.5th bootstrap percentiles.
WITH f AS (SELECT 322000000::DOUBLE / (SELECT COUNT(DISTINCT person_id) FROM person_map) AS factor),
pt AS (
    SELECT brand, SUM(n_clicks) AS clicks, SUM(converted) AS converted, SUM(purchased) AS purchased,
           COUNT(*) AS people
    FROM person_brand GROUP BY brand
),
bs AS (
    SELECT brand,
           QUANTILE_CONT(clicks, 0.025)    AS clicks_lo,    QUANTILE_CONT(clicks, 0.975)    AS clicks_hi,
           QUANTILE_CONT(converted, 0.025) AS conv_lo,      QUANTILE_CONT(converted, 0.975) AS conv_hi,
           QUANTILE_CONT(100.0 * converted / NULLIF(clicks, 0), 0.025) AS cr_lo,
           QUANTILE_CONT(100.0 * converted / NULLIF(clicks, 0), 0.975) AS cr_hi
    FROM bootstrap_reps GROUP BY brand
)
SELECT pt.brand,
       pt.clicks                                   AS panel_clicks,
       pt.converted                                AS panel_conversions,
       ROUND(pt.clicks * f.factor)                 AS us_clicks,
       ROUND(bs.clicks_lo * f.factor)              AS us_clicks_lo,
       ROUND(bs.clicks_hi * f.factor)              AS us_clicks_hi,
       ROUND(pt.converted * f.factor)              AS us_conversions,
       ROUND(bs.conv_lo * f.factor)                AS us_conversions_lo,
       ROUND(bs.conv_hi * f.factor)                AS us_conversions_hi,
       ROUND(pt.purchased * f.factor)              AS us_purchases,
       ROUND(100.0 * pt.converted / pt.clicks, 2)  AS conversion_rate_pct,
       ROUND(bs.cr_lo, 2)                          AS conversion_rate_lo,
       ROUND(bs.cr_hi, 2)                          AS conversion_rate_hi
FROM pt JOIN bs USING (brand) CROSS JOIN f
ORDER BY pt.clicks DESC, pt.brand;


-- name: small_count_intervals
-- Small counts: Garwood exact interval on people who clicked (chi-square values for k = 0..10),
-- times clicks per person; Clopper-Pearson upper bound when 0 people converted.
WITH garwood(k, lo, hi) AS (
    VALUES (0, 0.000, 3.689), (1, 0.025, 5.572), (2, 0.242, 7.225), (3, 0.619, 8.767),
           (4, 1.090, 10.242), (5, 1.623, 11.668), (6, 2.202, 13.059), (7, 2.814, 14.423),
           (8, 3.454, 15.763), (9, 4.115, 17.085), (10, 4.795, 18.390)
),
f AS (SELECT 322000000::DOUBLE / (SELECT COUNT(DISTINCT person_id) FROM person_map) AS factor),
pt AS (SELECT brand, SUM(n_clicks) AS clicks, COUNT(*) AS people, SUM(converted) AS converted
       FROM person_brand GROUP BY brand)
SELECT pt.brand, pt.clicks AS panel_clicks, pt.people AS panel_people_clicked,
       ROUND(g.lo * pt.clicks / pt.people * f.factor) AS us_clicks_exact_lo,
       ROUND(pt.clicks * f.factor)                    AS us_clicks,
       ROUND(g.hi * pt.clicks / pt.people * f.factor) AS us_clicks_exact_hi,
       pt.converted                                   AS panel_conversions,
       CASE WHEN pt.converted = 0 THEN ROUND(100.0 * (1 - POW(0.025, 1.0 / pt.people)), 1) END AS people_converted_upper_bound_pct
FROM pt JOIN garwood g ON g.k = pt.people CROSS JOIN f
ORDER BY pt.clicks DESC, pt.brand;


-- name: bootstrap_check
-- Bootstrap mean should match the point estimate.
SELECT b.brand,
       ROUND(AVG(b.clicks), 1)    AS mean_boot_clicks,
       (SELECT SUM(n_clicks) FROM person_brand p WHERE p.brand = b.brand) AS point_clicks,
       ROUND(AVG(b.converted), 1) AS mean_boot_conversions,
       (SELECT SUM(converted) FROM person_brand p WHERE p.brand = b.brand) AS point_conversions,
       COUNT(*)                   AS n_replicates
FROM bootstrap_reps b
GROUP BY b.brand
ORDER BY b.brand;


-- name: dtc_pooled_bounds
-- DTC zeros pooled into one bound (Clopper-Pearson):
--   people who clicked a DTC affiliate link, and all visitors of the four DTC sites.
WITH aff AS (
    SELECT 'DTC people who clicked an affiliate link (pooled)' AS population,
           COUNT(*) AS n, SUM(converted) AS k
    FROM person_brand WHERE brand <> 'walmart'
),
vis AS (
    SELECT 'DTC site visitors, any channel (pooled)' AS population,
           COUNT(*) AS n,
           COUNT(*) FILTER (WHERE purchased) AS k
    FROM (
        SELECT b.brand, pm.person_id,
               BOOL_OR(c.person_id IS NOT NULL) AS purchased
        FROM bu_events b
        JOIN person_map pm USING (USER_ID)
        LEFT JOIN conversion_events c
               ON c.brand = b.brand AND c.person_id = pm.person_id AND c.tier = 'purchase'
        WHERE b.brand IN ('saatva', 'nectar', 'helix', 'dreamcloud')
        GROUP BY b.brand, pm.person_id
    )
)
SELECT population, n, k,
       ROUND(100.0 * k / n, 2)                                               AS observed_pct,
       CASE WHEN k = 0 THEN ROUND(100.0 * (1 - POW(0.025, 1.0 / n)), 1) END AS upper_bound_pct_95
FROM (SELECT * FROM aff UNION ALL SELECT * FROM vis)
ORDER BY n;


-- name: dtc_benchmark_scenario
-- Scenario, not a measurement: US clicks x Home & Furniture conversion rate (1.29%, Dynamic Yield
-- via Shopify, June 2026). Variant: x the affiliate uplift seen on Walmart in this data.
-- Click range: Garwood for <= 10 people, normal approximation above.
WITH params AS (SELECT 0.0129 AS benchmark_cr),
f AS (SELECT 322000000::DOUBLE / (SELECT COUNT(DISTINCT person_id) FROM person_map) AS factor),
garwood(k, lo, hi) AS (
    VALUES (0, 0.000, 3.689), (1, 0.025, 5.572), (2, 0.242, 7.225), (3, 0.619, 8.767),
           (4, 1.090, 10.242), (5, 1.623, 11.668), (6, 2.202, 13.059), (7, 2.814, 14.423),
           (8, 3.454, 15.763), (9, 4.115, 17.085), (10, 4.795, 18.390)
),
wm AS (   -- affiliate uplift on Walmart, measured in this data
    SELECT AVG(CASE WHEN aff THEN bought END) / AVG(CASE WHEN NOT aff THEN bought END) AS uplift
    FROM (
        SELECT pm.person_id,
               BOOL_OR(k.person_id IS NOT NULL)                     AS aff,
               MAX(CASE WHEN c.person_id IS NOT NULL THEN 1.0 ELSE 0.0 END) AS bought
        FROM bu_events b
        JOIN person_map pm USING (USER_ID)
        LEFT JOIN (SELECT DISTINCT person_id FROM affiliate_clicks
                   WHERE brand = 'walmart' AND NOT is_panel_duplicate) k ON k.person_id = pm.person_id
        LEFT JOIN conversion_events c
               ON c.brand = 'walmart' AND c.person_id = pm.person_id AND c.tier = 'purchase'
        WHERE b.brand = 'walmart'
        GROUP BY pm.person_id
    )
),
pt AS (SELECT brand, SUM(n_clicks) AS clicks, COUNT(*) AS people FROM person_brand WHERE brand <> 'walmart' GROUP BY brand),
r AS (
    SELECT pt.brand, pt.clicks,
           COALESCE(g.lo, GREATEST(pt.people - 1.96 * SQRT(pt.people), 0)) * pt.clicks / pt.people AS lo,
           COALESCE(g.hi, pt.people + 1.96 * SQRT(pt.people))              * pt.clicks / pt.people AS hi
    FROM pt LEFT JOIN garwood g ON g.k = pt.people
)
SELECT r.brand,
       ROUND(r.clicks * f.factor)                                        AS us_clicks,
       ROUND(r.lo * f.factor)                                            AS us_clicks_lo,
       ROUND(r.hi * f.factor)                                            AS us_clicks_hi,
       p.benchmark_cr * 100                                              AS benchmark_cr_pct,
       ROUND(r.clicks * f.factor * p.benchmark_cr)                       AS scenario_conversions,
       ROUND(r.lo * f.factor * p.benchmark_cr)                           AS scenario_conversions_lo,
       ROUND(r.hi * f.factor * p.benchmark_cr)                           AS scenario_conversions_hi,
       ROUND(wm.uplift, 2)                                               AS walmart_affiliate_uplift,
       ROUND(r.clicks * f.factor * p.benchmark_cr * wm.uplift)           AS scenario_conversions_with_uplift
FROM r CROSS JOIN f CROSS JOIN params p CROSS JOIN wm
ORDER BY r.clicks DESC, r.brand;

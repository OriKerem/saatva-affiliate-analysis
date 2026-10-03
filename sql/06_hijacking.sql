-- 06_hijacking.sql
-- Attribution hijacking: organic, direct, social or paid traffic that receives an affiliate tag
-- (last click wins, so the last tag gets the commission).
-- Needs bu_events (01), affiliate_landings / affiliate_clicks / person_map (03), click_conversions (04).
--
-- Entry path of each click, from the page just before it and the landing URL (first match wins):
--   paid_search      gclid / gad_source / gbraid / wbraid / msclkid / veh=sem, or an ad redirect before
--   social           fbclid, or a social network before
--   same_site        the brand's own site before (tag appeared mid-visit)
--   cashback_coupon  cash-back / coupon site or extension before
--   comparison       price-comparison engine (Bizrate, Kelkoo, ...)
--   creator          creator link service (Mavely, ShopYourLikes, LTK, ...)
--   content          review / editorial site
--   other_site / none
--
-- Signals (a reason to review, not proof):
--   S1 paid_tagged        paid-search marker on the affiliate landing
--   S2 social_tagged      social click ID on the affiliate landing
--   S3 mid_visit_tagged   entry path same_site
--   S4 publisher_switch   another publisher's click, same person and brand, within 30 min
--      S4a via a comparison engine (mostly normal comparison shopping)
--      S4b stand-down violation: previous click had afsrc=1, switch within 60 s, already on the site
--   S5 checkout_click     click credited with a purchase less than 60 s later
--   S6 publisher_cycling  3+ publishers for the same person and brand in one visit
--   S7 extension_before   cash-back / coupon site or extension in the 10 min before
-- Tiers: strong = S1, S4b, S5; possible = S2, S3; hijack_definition = strong or possible.
-- S4 and S7 are context. Counted by clicks and by people.


-- name: entry_path_discovery
-- Most common pages right before an affiliate click, per brand.
SELECT brand, COALESCE(entry_prev_host, '(none)') AS prev_host,
       COUNT(*) AS n_clicks, COUNT(DISTINCT person_id) AS n_people
FROM affiliate_clicks
WHERE NOT is_panel_duplicate
GROUP BY brand, COALESCE(entry_prev_host, '(none)')
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand ORDER BY COUNT(*) DESC, COALESCE(entry_prev_host, '(none)')) <= 40
ORDER BY brand, n_clicks DESC, prev_host;


-- name: build_click_signals
-- One row per affiliate click: entry path and the seven signals.
CREATE OR REPLACE TABLE click_signals AS
WITH k AS (
    SELECT brand, person_id, USER_ID, SESSION_ID, click_time, publisher_id,
           COALESCE(entry_prev_host, '') AS prev_host,
           LOWER(landing_url) AS landing_url, m_paid_search, m_afsrc
    FROM affiliate_clicks
    WHERE NOT is_panel_duplicate
),
typed AS (
    SELECT k.*,
           CASE
               WHEN m_paid_search
                 OR REGEXP_MATCHES(prev_host, '(googleadservices|doubleclick|dartsearch|bat\.bing|ads\.bing)')
                    THEN 'paid_search'
               WHEN REGEXP_MATCHES(landing_url, '[?&](fbclid|ttclid|twclid|igshid)=')
                 OR REGEXP_MATCHES(prev_host, '(^|\.)(facebook|instagram|tiktok|pinterest|reddit|youtube|x|t|threads|snapchat|linkedin)\.(com|co)$|(^|\.)t\.co$|(^|\.)lm\.facebook\.com$')
                    THEN 'social'
               WHEN prev_host <> '' AND REGEXP_MATCHES(prev_host, CASE brand
                        WHEN 'walmart'    THEN '(^|\.)walmart\.com$'
                        WHEN 'saatva'     THEN '(^|\.)saatva\.com$'
                        WHEN 'nectar'     THEN '(^|\.)nectarsleep\.com$'
                        WHEN 'helix'      THEN '(^|\.)helixsleep\.com$'
                        WHEN 'dreamcloud' THEN '(^|\.)dreamcloudsleep\.com$' END)
                    THEN 'same_site'
               WHEN REGEXP_MATCHES(prev_host, '(capitalone(shopping|offers)|joinhoney|honey\.|rakuten|retailmenot|simplycodes|coupon|cashback|topcashback|befrugal|ibotta|dealspotr|slickdeals|deals?(and|finder|find)|discountswithdeals)')
                    THEN 'cashback_coupon'
               WHEN REGEXP_MATCHES(prev_host, '(bizrate|kelkoo|pricegrabber|shopzilla|shopping\.com|connexity)')
                    THEN 'comparison'
               WHEN REGEXP_MATCHES(prev_host, '(mavely|mavlink|sylikes|shopyourlikes|golikely|shopltk|rstyle\.me|liketoknow|howl\.(me|link)|creator)')
                    THEN 'creator'
               WHEN REGEXP_MATCHES(prev_host, '(mattressclarity|mattressnrd|mattressnerd|sleepfoundation|sleepopolis|buyersguide|rtings|wirecutter|nytimes|cnet|tomsguide|forbes|consumerreports|goodhousekeeping|purewow|bestreviews)')
                    THEN 'content'
               WHEN prev_host = '' THEN 'none'
               ELSE 'other_site'
           END AS entry_type
    FROM k
),
seq AS (
    SELECT t.*,
           LAG(click_time)   OVER w AS prev_click_time,
           LAG(publisher_id) OVER w AS prev_publisher,
           LAG(m_afsrc)      OVER w AS prev_afsrc
    FROM typed t
    WINDOW w AS (PARTITION BY brand, person_id ORDER BY click_time, publisher_id, USER_ID)
),
cyc AS (   -- distinct publishers per person, brand and visit
    SELECT brand, person_id, SESSION_ID, COUNT(DISTINCT publisher_id) AS publishers_in_visit
    FROM typed GROUP BY ALL
),
chk AS (   -- clicks that got the credit for a purchase within 60 seconds
    SELECT DISTINCT brand, person_id, credited_click_time
    FROM click_conversions
    WHERE tier = 'purchase' AND seconds_click_to_conversion < 60
),
ext AS (   -- cash-back / coupon page or extension activity in the 10 minutes before the click
    SELECT DISTINCT t.brand, t.person_id, t.click_time
    FROM typed t
    JOIN bu_events e
      ON e.USER_ID = t.USER_ID
     AND e.CREATED_TIME >= t.click_time - INTERVAL 10 MINUTE AND e.CREATED_TIME < t.click_time
    WHERE REGEXP_MATCHES(e.host, '(capitalone(shopping|offers)|joinhoney|honey\.|rakuten|retailmenot|simplycodes|topcashback|befrugal|ibotta|karmanow|dealspotr)')
)
SELECT s.brand, s.person_id, s.USER_ID, s.SESSION_ID, s.click_time, s.publisher_id, s.prev_host, s.entry_type,
       s.m_afsrc,
       s.m_paid_search                                         AS s1_paid_tagged,
       s.entry_type = 'social'                                 AS s2_social_tagged,
       s.entry_type = 'same_site'                              AS s3_mid_visit_tagged,
       (s.prev_publisher IS NOT NULL AND s.prev_publisher <> s.publisher_id
        AND DATE_DIFF('second', s.prev_click_time, s.click_time) <= 1800) AS s4_publisher_switch,
       (s.prev_publisher IS NOT NULL AND s.prev_publisher <> s.publisher_id
        AND DATE_DIFF('second', s.prev_click_time, s.click_time) <= 1800
        AND s.entry_type = 'comparison')                       AS s4a_switch_from_comparison,
       (s.prev_publisher IS NOT NULL AND s.prev_publisher <> s.publisher_id
        AND s.prev_afsrc
        AND DATE_DIFF('second', s.prev_click_time, s.click_time) <= 60
        AND s.entry_type = 'same_site')                        AS s4b_standdown_violation,
       DATE_DIFF('second', s.prev_click_time, s.click_time)   AS seconds_since_prev_click,
       (chk.person_id IS NOT NULL)                             AS s5_checkout_click,
       (cyc.publishers_in_visit >= 3)                          AS s6_publisher_cycling,
       cyc.publishers_in_visit,
       (ext.person_id IS NOT NULL)                             AS s7_extension_before
FROM seq s
LEFT JOIN cyc ON cyc.brand = s.brand AND cyc.person_id = s.person_id AND cyc.SESSION_ID = s.SESSION_ID
LEFT JOIN chk ON chk.brand = s.brand AND chk.person_id = s.person_id AND chk.credited_click_time = s.click_time
LEFT JOIN ext ON ext.brand = s.brand AND ext.person_id = s.person_id AND ext.click_time = s.click_time;


-- name: entry_path_by_brand
-- Entry path per brand (clicks and people).
SELECT brand, entry_type,
       COUNT(*)                                              AS n_clicks,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY brand), 1) AS pct_clicks,
       COUNT(DISTINCT person_id)                             AS n_people
FROM click_signals
GROUP BY brand, entry_type
ORDER BY brand, n_clicks DESC, entry_type;


-- name: signals_by_brand
-- Signals and tiers per brand, by clicks and by people.
WITH s AS (
    SELECT *,
           (s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click)               AS strong,
           (s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click
            OR s2_social_tagged OR s3_mid_visit_tagged)                                   AS hijack_definition
    FROM click_signals
),
u AS (
    SELECT brand, person_id, signal, flag
    FROM s
    UNPIVOT (flag FOR signal IN (s1_paid_tagged, s2_social_tagged, s3_mid_visit_tagged, s4_publisher_switch,
                                 s4a_switch_from_comparison, s4b_standdown_violation, s5_checkout_click,
                                 s6_publisher_cycling, s7_extension_before, hijack_definition, strong))
)
SELECT brand, signal,
       SUM(CASE WHEN flag THEN 1 ELSE 0 END)                         AS n_clicks,
       ROUND(100.0 * SUM(CASE WHEN flag THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_clicks,
       COUNT(DISTINCT CASE WHEN flag THEN person_id END)             AS n_people,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN flag THEN person_id END) / COUNT(DISTINCT person_id), 1) AS pct_people
FROM u
GROUP BY brand, signal
ORDER BY brand, signal;


-- name: switch_concentration
-- Publisher switches: people by number of switches, and where the switching click came from.
WITH p AS (
    SELECT brand, person_id, SUM(CASE WHEN s4_publisher_switch THEN 1 ELSE 0 END) AS n_switches
    FROM click_signals GROUP BY brand, person_id
),
b AS (
    SELECT brand, n_switches,
           CASE WHEN n_switches = 0 THEN 0 WHEN n_switches = 1 THEN 1 WHEN n_switches <= 3 THEN 2
                WHEN n_switches <= 9 THEN 3 ELSE 4 END AS bucket
    FROM p
)
SELECT brand,
       CASE bucket WHEN 0 THEN '0' WHEN 1 THEN '1' WHEN 2 THEN '2-3' WHEN 3 THEN '4-9' ELSE '10+' END AS switches_per_person,
       COUNT(*)        AS n_people,
       SUM(n_switches) AS n_switches,
       ROUND(100.0 * SUM(n_switches) / NULLIF(SUM(SUM(n_switches)) OVER (PARTITION BY brand), 0), 1) AS pct_of_switches
FROM b
GROUP BY brand, bucket
ORDER BY brand, bucket;


-- name: switch_by_entry_type
SELECT brand, entry_type,
       COUNT(*) AS n_switches, COUNT(DISTINCT person_id) AS n_people,
       SUM(CASE WHEN s4b_standdown_violation THEN 1 ELSE 0 END) AS of_which_standdown_violation
FROM click_signals
WHERE s4_publisher_switch
GROUP BY brand, entry_type
ORDER BY brand, n_switches DESC, entry_type;


-- name: publisher_risk
-- Publisher scorecard (>= 5 clicks). red_flags = number of thresholds crossed:
-- clicks per person >= 5, mid-visit >= 50%, stand-down violations >= 1, checkout clicks >= 25% of
-- credited purchases, cycling >= 50% (skipped for comparison engines), extension >= 25%,
-- paid or social >= 50%.
WITH c AS (
    SELECT brand, publisher_id,
           COUNT(*) AS n_clicks, COUNT(DISTINCT person_id) AS n_people,
           AVG(CASE WHEN s3_mid_visit_tagged THEN 1.0 ELSE 0 END)                         AS mid_visit_share,
           SUM(CASE WHEN s4b_standdown_violation THEN 1 ELSE 0 END)                       AS standdown_violations,
           SUM(CASE WHEN s5_checkout_click THEN 1 ELSE 0 END)                             AS checkout_clicks,
           AVG(CASE WHEN s6_publisher_cycling THEN 1.0 ELSE 0 END)                        AS cycling_share,
           AVG(CASE WHEN s7_extension_before THEN 1.0 ELSE 0 END)                         AS extension_share,
           AVG(CASE WHEN s1_paid_tagged OR s2_social_tagged THEN 1.0 ELSE 0 END)          AS paid_social_share,
           MODE() WITHIN GROUP (ORDER BY entry_type)                                      AS main_entry_type
    FROM click_signals
    GROUP BY brand, publisher_id
),
p AS (
    SELECT brand, credited_publisher AS publisher_id,
           COUNT(DISTINCT person_id) AS purchases_credited
    FROM click_conversions WHERE tier = 'purchase'
    GROUP BY ALL
)
SELECT c.brand, c.publisher_id, c.main_entry_type, c.n_clicks, c.n_people,
       ROUND(c.n_clicks / c.n_people, 1)            AS clicks_per_person,
       ROUND(100 * c.mid_visit_share, 0)            AS pct_mid_visit,
       c.standdown_violations,
       COALESCE(p.purchases_credited, 0)            AS purchases_credited,
       c.checkout_clicks,
       ROUND(100 * c.cycling_share, 0)              AS pct_cycling,
       ROUND(100 * c.extension_share, 0)            AS pct_extension_before,
       ROUND(100 * c.paid_social_share, 0)          AS pct_paid_or_social,
       (CASE WHEN c.n_clicks / c.n_people >= 5 THEN 1 ELSE 0 END
      + CASE WHEN c.mid_visit_share >= 0.5 THEN 1 ELSE 0 END
      + CASE WHEN c.standdown_violations >= 1 THEN 1 ELSE 0 END
      + CASE WHEN p.purchases_credited > 0 AND c.checkout_clicks >= 0.25 * p.purchases_credited THEN 1 ELSE 0 END
      + CASE WHEN c.cycling_share >= 0.5 AND c.main_entry_type <> 'comparison' THEN 1 ELSE 0 END
      + CASE WHEN c.extension_share >= 0.25 THEN 1 ELSE 0 END
      + CASE WHEN c.paid_social_share >= 0.5 THEN 1 ELSE 0 END)  AS red_flags
FROM c LEFT JOIN p USING (brand, publisher_id)
WHERE c.n_clicks >= 5
QUALIFY ROW_NUMBER() OVER (PARTITION BY c.brand ORDER BY red_flags DESC, c.n_clicks DESC, c.publisher_id) <= 25
ORDER BY c.brand, red_flags DESC, c.n_clicks DESC, c.publisher_id;


-- name: commission_at_risk
-- Affiliate-credited purchases with a signal on the credited click: commission possibly paid
-- for visits the affiliate did not bring. strong = conservative; any = upper bound.
WITH cp AS (
    SELECT c.brand, c.person_id, c.credited_click_time, c.n_publishers_before
    FROM click_conversions c WHERE c.tier = 'purchase'
),
j AS (
    SELECT cp.brand, cp.n_publishers_before, s.*
    FROM cp JOIN click_signals s
      ON s.brand = cp.brand AND s.person_id = cp.person_id AND s.click_time = cp.credited_click_time
)
SELECT brand,
       COUNT(*)                                                                   AS purchases_credited,
       SUM(s1_paid_tagged::INT)                                                   AS s1_paid,
       SUM(s4b_standdown_violation::INT)                                          AS s4b_standdown,
       SUM(s5_checkout_click::INT)                                                AS s5_checkout,
       SUM(s2_social_tagged::INT)                                                 AS s2_social,
       SUM(s3_mid_visit_tagged::INT)                                              AS s3_mid_visit,
       SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click)::INT) AS strong,
       ROUND(100.0 * SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click)::INT) / COUNT(*), 1) AS pct_strong,
       SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click
            OR s2_social_tagged OR s3_mid_visit_tagged)::INT)                     AS hijack_definition,
       ROUND(100.0 * SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click
            OR s2_social_tagged OR s3_mid_visit_tagged)::INT) / COUNT(*), 1)     AS pct_hijack_definition,
       SUM((n_publishers_before > 1)::INT)                                        AS another_publisher_before,
       SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click OR s2_social_tagged
            OR s3_mid_visit_tagged OR s7_extension_before OR n_publishers_before > 1)::INT) AS any_signal,
       ROUND(100.0 * SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click OR s2_social_tagged
            OR s3_mid_visit_tagged OR s7_extension_before OR n_publishers_before > 1)::INT) / COUNT(*), 1) AS pct_any_signal
FROM j
GROUP BY brand
ORDER BY purchases_credited DESC, brand;


-- name: paid_tagged_by_publisher
-- S1 by publisher: previous page, and how many distinct ad click IDs (msclkid / gclid).
-- Many distinct IDs = real ad clicks sent to the affiliate link. wl0..wl14 = Walmart search-campaign
-- parameters. Arbitrage or an agreed setup look the same here: a question for the network.
SELECT s.brand,
       s.publisher_id,
       COUNT(*)                                                                         AS n_clicks,
       COUNT(DISTINCT s.person_id)                                                      AS n_people,
       MODE() WITHIN GROUP (ORDER BY s.prev_host)                                       AS main_prev_host,
       SUM(CASE WHEN s.prev_host = 'rd.bizrate.com' THEN 1 ELSE 0 END)                  AS via_bizrate,
       SUM(CASE WHEN REGEXP_MATCHES(a.landing_url, '[?&]msclkid=') THEN 1 ELSE 0 END)   AS with_msclkid,
       COUNT(DISTINCT REGEXP_EXTRACT(a.landing_url, '[?&]msclkid=([^&#]+)', 1))
           FILTER (WHERE REGEXP_MATCHES(a.landing_url, '[?&]msclkid='))                 AS distinct_msclkid,
       SUM(CASE WHEN REGEXP_MATCHES(a.landing_url, '[?&](gclid|gad_source|gbraid|wbraid)=') THEN 1 ELSE 0 END) AS with_google_marker,
       SUM(CASE WHEN REGEXP_MATCHES(a.landing_url, '[?&]wl0=') THEN 1 ELSE 0 END)       AS with_walmart_campaign_params
FROM click_signals s
JOIN affiliate_clicks a
  ON a.brand = s.brand AND a.USER_ID = s.USER_ID AND a.click_time = s.click_time AND NOT a.is_panel_duplicate
WHERE s.s1_paid_tagged
GROUP BY s.brand, s.publisher_id
ORDER BY n_clicks DESC, s.brand, s.publisher_id;


-- name: dtc_click_signals
-- DTC affiliate clicks with entry path and signals (no URLs).
SELECT brand, click_time, publisher_id, prev_host, entry_type, m_afsrc,
       s1_paid_tagged, s2_social_tagged, s3_mid_visit_tagged, s4_publisher_switch, s4b_standdown_violation,
       s5_checkout_click, s6_publisher_cycling, s7_extension_before
FROM click_signals
WHERE brand <> 'walmart'
ORDER BY brand, click_time, publisher_id;

-- 07_competitive_benchmark.sql
-- Saatva vs. competitors: channel mix, publishers, cross-shopping, and one scorecard.
-- Needs bu_events (01), person_map / affiliate_clicks (03), conversion_events (04),
-- walmart_mattress_pages / segment_clicks / segment_bootstrap (05b), click_signals (06).
-- Walmart is compared through its mattress section; walmart_all appears only in the scorecard.
--
-- Visit = person x segment x session; entry = first event of the session on the brand site.
-- Channel, from the entry URL and the page before it (first match wins):
--   affiliate       affiliate marker (step 03 rules)
--   paid_search     gclid / gad_source / gbraid / wbraid / msclkid, utm_medium=cpc|ppc|paid, veh=sem, wmlspartner=wlpa
--   email           utm_medium=email|newsletter, veh=eml, or a webmail / brand e-mail host before
--   social          fbclid / ttclid, social utm_source, or a social network before
--   other_campaign  any other utm_medium (display, streaming TV, sms, ...)
--   review_content  review / editorial site before
--   competitor      another mattress brand before
--   other_site      any other page before
--   direct_unknown  nothing before, or the brand's own site (search pages are not in the panel,
--                   so organic search ends up here)


-- name: build_brand_visits
CREATE OR REPLACE TABLE brand_visits AS
WITH ev AS (   -- brand-site events, mapped to comparison segments
    SELECT b.brand AS segment, b.USER_ID, b.SESSION_ID, b.CREATED_TIME, b._ID, b.URL, b.prev_host
    FROM bu_events b
    WHERE b.brand IN ('saatva', 'nectar', 'helix', 'dreamcloud')
    UNION ALL
    SELECT 'walmart_mattress', b.USER_ID, b.SESSION_ID, b.CREATED_TIME, b._ID, b.URL, b.prev_host
    FROM bu_events b
    WHERE b.brand = 'walmart'
      AND EXISTS (SELECT 1 FROM walmart_mattress_pages m
                  WHERE m.USER_ID = b.USER_ID AND m.SESSION_ID = b.SESSION_ID)
),
entry AS (
    SELECT segment, USER_ID, SESSION_ID,
           MIN(CREATED_TIME)                                                       AS entry_time,
           LOWER(ARG_MIN(URL, {'t': CREATED_TIME, 'i': _ID}))                       AS entry_url,
           COALESCE(ARG_MIN(prev_host, {'t': CREATED_TIME, 'i': _ID}), '')          AS prev_host,
           COUNT(*)                                                                AS pages_in_visit
    FROM ev
    GROUP BY segment, USER_ID, SESSION_ID
)
SELECT e.segment, pm.person_id, e.USER_ID, e.SESSION_ID, e.entry_time, e.prev_host, e.pages_in_visit,
       CASE
           WHEN REGEXP_MATCHES(e.entry_url, '[?&](utm_medium=(affiliate|aff)(&|$)|click_id=|app_clickref=|clickref=|irgwc=1|irclickid=|cidimp=|veh=aff(&|$)|wmlspartner(_creator)?=imp_|sourceid=imp_|affiliates_ad_id)')
                THEN 'affiliate'
           WHEN REGEXP_MATCHES(e.entry_url, '[?&]((gclid|gad_source|gbraid|wbraid|msclkid)=|utm_medium=(cpc|ppc|paid|paidsearch|sem)(&|$)|veh=sem|wmlspartner=wlpa)')
             OR REGEXP_MATCHES(e.prev_host, '(googleadservices|doubleclick|dartsearch)')
                THEN 'paid_search'
           WHEN REGEXP_MATCHES(e.entry_url, '[?&](utm_medium=(email|e-mail|newsletter)(&|$)|veh=eml)')
             OR REGEXP_MATCHES(e.prev_host, '(^|\.)(mail\.google\.com|outlook\.(live|office)\.com|mail\.yahoo\.com|mail\.aol\.com)$|emails?\.')
                THEN 'email'
           WHEN REGEXP_MATCHES(e.entry_url, '[?&](fbclid|ttclid|twclid)=|[?&]utm_source=(facebook|fb|instagram|ig|tiktok|pinterest)(&|$)')
             OR REGEXP_MATCHES(e.prev_host, '(^|\.)(facebook|instagram|tiktok|pinterest|reddit|youtube|x)\.com$|(^|\.)t\.co$')
                THEN 'social'
           WHEN REGEXP_MATCHES(e.entry_url, '[?&]utm_medium=')
                THEN 'other_campaign'
           WHEN REGEXP_MATCHES(e.prev_host, '(mattressclarity|mattressnrd|mattressnerd|sleepfoundation|sleepopolis|buyersguide|rtings|wirecutter|nytimes|cnet|tomsguide|forbes|consumerreports|goodhousekeeping|bestreviews|mattressadvisor|sleepdoctor)')
                THEN 'review_content'
           WHEN REGEXP_MATCHES(e.prev_host, '(^|\.)(saatva|nectarsleep|helixsleep|dreamcloudsleep|purple|casper|tempurpedic|sleepnumber|brooklynbedding|birchliving|leesa|tuftandneedle|avocadogreenmattress|zinus|sienasleep|awarasleep|bearmattress|nolahmattress|sealy|serta|mattressfirm)\.com$')
             AND NOT REGEXP_MATCHES(e.prev_host, CASE e.segment
                        WHEN 'saatva' THEN 'saatva' WHEN 'nectar' THEN 'nectarsleep' WHEN 'helix' THEN 'helixsleep'
                        WHEN 'dreamcloud' THEN 'dreamcloudsleep' ELSE 'walmart' END)
                THEN 'competitor'
           WHEN e.prev_host = ''
             OR REGEXP_MATCHES(e.prev_host, CASE e.segment
                        WHEN 'saatva' THEN 'saatva' WHEN 'nectar' THEN 'nectarsleep' WHEN 'helix' THEN 'helixsleep'
                        WHEN 'dreamcloud' THEN 'dreamcloudsleep' ELSE 'walmart' END)
                THEN 'direct_unknown'
           ELSE 'other_site'
       END AS channel
FROM entry e
JOIN person_map pm USING (USER_ID)
-- duplicate IDs of one person give identical visits: keep one per person and entry time
QUALIFY ROW_NUMBER() OVER (PARTITION BY e.segment, pm.person_id, e.entry_time ORDER BY e.USER_ID) = 1;


-- name: channel_mix
-- Share of visits per channel and brand (people in brackets).
SELECT segment, channel,
       COUNT(*)                                                                 AS visits,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY segment), 1)   AS pct_visits,
       COUNT(DISTINCT person_id)                                                AS people
FROM brand_visits
GROUP BY segment, channel
ORDER BY CASE segment WHEN 'saatva' THEN 1 WHEN 'nectar' THEN 2 WHEN 'helix' THEN 3 WHEN 'dreamcloud' THEN 4 ELSE 5 END,
         visits DESC, channel;


-- name: channel_mix_wide
-- Same, one row per brand.
SELECT segment,
       COUNT(*)                                                                         AS visits,
       COUNT(DISTINCT person_id)                                                        AS people,
       ROUND(100.0 * AVG(CASE WHEN channel = 'affiliate'      THEN 1 ELSE 0 END), 1)    AS pct_affiliate,
       ROUND(100.0 * AVG(CASE WHEN channel = 'paid_search'    THEN 1 ELSE 0 END), 1)    AS pct_paid_search,
       ROUND(100.0 * AVG(CASE WHEN channel = 'email'          THEN 1 ELSE 0 END), 1)    AS pct_email,
       ROUND(100.0 * AVG(CASE WHEN channel = 'social'         THEN 1 ELSE 0 END), 1)    AS pct_social,
       ROUND(100.0 * AVG(CASE WHEN channel = 'other_campaign' THEN 1 ELSE 0 END), 1)    AS pct_other_campaign,
       ROUND(100.0 * AVG(CASE WHEN channel = 'review_content' THEN 1 ELSE 0 END), 1)    AS pct_review_content,
       ROUND(100.0 * AVG(CASE WHEN channel = 'competitor'     THEN 1 ELSE 0 END), 1)    AS pct_from_competitor,
       ROUND(100.0 * AVG(CASE WHEN channel = 'other_site'     THEN 1 ELSE 0 END), 1)    AS pct_other_site,
       ROUND(100.0 * AVG(CASE WHEN channel = 'direct_unknown' THEN 1 ELSE 0 END), 1)    AS pct_direct_unknown
FROM brand_visits
GROUP BY segment
ORDER BY CASE segment WHEN 'saatva' THEN 1 WHEN 'nectar' THEN 2 WHEN 'helix' THEN 3 WHEN 'dreamcloud' THEN 4 ELSE 5 END;


-- name: referring_sites_by_brand
-- Sites that send visitors to each brand, and whether the visit had an affiliate tag.
-- A review site that sends to rivals as an affiliate but not to Saatva = a site to recruit.
SELECT prev_host,
       COUNT(*) FILTER (WHERE segment = 'saatva')             AS to_saatva,
       COUNT(*) FILTER (WHERE segment = 'nectar')             AS to_nectar,
       COUNT(*) FILTER (WHERE segment = 'helix')              AS to_helix,
       COUNT(*) FILTER (WHERE segment = 'dreamcloud')         AS to_dreamcloud,
       COUNT(*) FILTER (WHERE segment = 'walmart_mattress')   AS to_walmart_mattress,
       COUNT(*) FILTER (WHERE channel = 'affiliate')          AS of_which_affiliate,
       MIN(channel)                                           AS example_channel
FROM brand_visits
WHERE prev_host <> ''
  AND channel IN ('affiliate', 'review_content', 'other_site', 'competitor', 'social', 'email')
GROUP BY prev_host
HAVING COUNT(*) >= 2 OR COUNT(*) FILTER (WHERE channel IN ('affiliate', 'review_content')) >= 1
ORDER BY COUNT(*) DESC, prev_host
LIMIT 60;


-- name: affiliate_publishers_by_brand
-- Affiliate publishers per brand (Walmart: mattress section).
WITH k AS (
    SELECT CASE WHEN a.brand = 'walmart' THEN 'walmart_mattress' ELSE a.brand END AS segment,
           a.publisher_id, a.person_id, a.entry_prev_host, a.m_afsrc
    FROM affiliate_clicks a
    WHERE NOT a.is_panel_duplicate
      AND (a.brand <> 'walmart'
           OR EXISTS (SELECT 1 FROM walmart_mattress_pages m
                      WHERE m.USER_ID = a.USER_ID AND m.SESSION_ID = a.SESSION_ID))
)
SELECT segment, publisher_id,
       COUNT(*)                         AS clicks,
       COUNT(DISTINCT person_id)        AS people,
       MIN(entry_prev_host)             AS example_prev_host,
       BOOL_OR(m_afsrc)                 AS carries_afsrc
FROM k
GROUP BY segment, publisher_id
ORDER BY CASE segment WHEN 'saatva' THEN 1 WHEN 'nectar' THEN 2 WHEN 'helix' THEN 3 WHEN 'dreamcloud' THEN 4 ELSE 5 END,
         clicks DESC, publisher_id;


-- name: cross_shopping
-- People who visited more than one mattress brand that day: which brand next, and how soon.
WITH v AS (
    SELECT person_id, segment, MIN(entry_time) AS first_time
    FROM brand_visits GROUP BY person_id, segment
),
o AS (
    SELECT person_id, segment, first_time,
           LEAD(segment)    OVER (PARTITION BY person_id ORDER BY first_time, segment) AS next_segment,
           LEAD(first_time) OVER (PARTITION BY person_id ORDER BY first_time, segment) AS next_time
    FROM v
)
SELECT segment AS from_brand, next_segment AS to_brand,
       COUNT(*)                                                   AS people,
       MEDIAN(DATE_DIFF('second', first_time, next_time))         AS median_seconds_between
FROM o
WHERE next_segment IS NOT NULL
GROUP BY from_brand, to_brand
ORDER BY people DESC, from_brand, to_brand;


-- name: cross_shopping_share
-- Share of each brand's visitors who also visited another mattress brand.
WITH p AS (
    SELECT person_id, COUNT(DISTINCT segment) AS n_brands FROM brand_visits GROUP BY person_id
)
SELECT v.segment,
       COUNT(DISTINCT v.person_id)                                            AS people,
       COUNT(DISTINCT CASE WHEN p.n_brands > 1 THEN v.person_id END)          AS also_visited_another_brand,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN p.n_brands > 1 THEN v.person_id END)
             / COUNT(DISTINCT v.person_id), 1)                                AS pct_cross_shoppers
FROM brand_visits v JOIN p USING (person_id)
GROUP BY v.segment
ORDER BY CASE v.segment WHEN 'saatva' THEN 1 WHEN 'nectar' THEN 2 WHEN 'helix' THEN 3 WHEN 'dreamcloud' THEN 4 ELSE 5 END;


-- name: brand_scorecard
-- All headline numbers per brand in one table. walmart_all is context only.
WITH f AS (SELECT 322000000::DOUBLE / (SELECT COUNT(DISTINCT person_id) FROM person_map) AS factor),
garwood(k, lo, hi) AS (
    VALUES (0, 0.000, 3.689), (1, 0.025, 5.572), (2, 0.242, 7.225), (3, 0.619, 8.767),
           (4, 1.090, 10.242), (5, 1.623, 11.668), (6, 2.202, 13.059), (7, 2.814, 14.423),
           (8, 3.454, 15.763), (9, 4.115, 17.085), (10, 4.795, 18.390)
),
vis AS (
    SELECT segment, COUNT(DISTINCT person_id) AS site_visitors,
           ROUND(100.0 * AVG(CASE WHEN channel = 'affiliate' THEN 1 ELSE 0 END), 1)   AS pct_visits_affiliate,
           ROUND(100.0 * AVG(CASE WHEN channel = 'paid_search' THEN 1 ELSE 0 END), 1) AS pct_visits_paid_search
    FROM brand_visits GROUP BY segment
),
buy AS (
    SELECT 'walmart_mattress' AS segment, COUNT(DISTINCT c.person_id) AS visitors_purchased
    FROM conversion_events c
    WHERE c.brand = 'walmart' AND c.tier = 'purchase'
      AND c.person_id IN (SELECT person_id FROM walmart_mattress_pages)
    UNION ALL
    SELECT CASE WHEN brand = 'walmart' THEN 'walmart_all' ELSE brand END, COUNT(DISTINCT person_id)
    FROM conversion_events WHERE tier = 'purchase' GROUP BY 1
),
clk AS (
    SELECT segment, COUNT(*) AS affiliate_clicks, COUNT(DISTINCT person_id) AS people_clicked,
           SUM(converted) AS clicks_converted
    FROM segment_clicks GROUP BY segment
),
bs AS (
    SELECT segment, QUANTILE_CONT(clicks, 0.025) AS b_lo, QUANTILE_CONT(clicks, 0.975) AS b_hi
    FROM segment_bootstrap GROUP BY segment
),
sig AS (   -- signals of the segment's affiliate clicks
    SELECT CASE WHEN s.brand <> 'walmart' THEN s.brand
                WHEN EXISTS (SELECT 1 FROM walmart_mattress_pages m
                             WHERE m.USER_ID = s.USER_ID AND m.SESSION_ID = s.SESSION_ID) THEN 'walmart_mattress'
                ELSE NULL END AS segment,
           s.*
    FROM click_signals s
),
sg AS (
    SELECT segment,
           COUNT(DISTINCT publisher_id)                                                    AS publishers,
           ROUND(100.0 * AVG(m_afsrc::INT), 0)                                             AS pct_clicks_with_afsrc,
           SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click)::INT)      AS clicks_strong_signal,
           SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click
                OR s2_social_tagged OR s3_mid_visit_tagged)::INT)                          AS clicks_hijack_definition
    FROM sig WHERE segment IS NOT NULL GROUP BY segment
    UNION ALL
    SELECT 'walmart_all', COUNT(DISTINCT publisher_id), ROUND(100.0 * AVG(m_afsrc::INT), 0),
           SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click)::INT),
           SUM((s1_paid_tagged OR s4b_standdown_violation OR s5_checkout_click
                OR s2_social_tagged OR s3_mid_visit_tagged)::INT)
    FROM click_signals WHERE brand = 'walmart'
),
seg(segment, ord) AS (
    VALUES ('saatva', 1), ('nectar', 2), ('helix', 3), ('dreamcloud', 4), ('walmart_mattress', 5), ('walmart_all', 6)
)
SELECT s.segment,
       CASE WHEN s.segment = 'walmart_all' THEN 'context only' ELSE 'comparison' END              AS role,
       CASE WHEN s.segment = 'walmart_all'
            THEN (SELECT COUNT(DISTINCT pm.person_id) FROM bu_events b JOIN person_map pm USING (USER_ID)
                  WHERE b.brand = 'walmart')
            ELSE COALESCE(v.site_visitors, 0) END                                                  AS site_visitors,
       COALESCE(b.visitors_purchased, 0)                                                          AS visitors_purchased,
       v.pct_visits_affiliate,
       v.pct_visits_paid_search,
       COALESCE(c.affiliate_clicks, 0)                                                            AS affiliate_clicks,
       COALESCE(c.people_clicked, 0)                                                              AS people_clicked,
       COALESCE(c.clicks_converted, 0)                                                            AS clicks_converted,
       ROUND(c.affiliate_clicks * f.factor)                                                       AS us_affiliate_clicks_per_day,
       ROUND(CASE WHEN c.people_clicked <= 10 THEN g.lo * c.affiliate_clicks / c.people_clicked ELSE bs.b_lo END * f.factor) AS us_clicks_lo,
       ROUND(CASE WHEN c.people_clicked <= 10 THEN g.hi * c.affiliate_clicks / c.people_clicked ELSE bs.b_hi END * f.factor) AS us_clicks_hi,
       CASE WHEN c.clicks_converted > 0 THEN ROUND(100.0 * c.clicks_converted / c.affiliate_clicks, 2) END AS conversion_rate_pct,
       CASE WHEN c.affiliate_clicks > 0 AND c.clicks_converted = 0
            THEN ROUND(100.0 * (1 - POW(0.025, 1.0 / c.people_clicked)), 1) END                  AS people_converted_upper_bound_pct,
       sg.publishers,
       sg.pct_clicks_with_afsrc,
       sg.clicks_strong_signal,
       sg.clicks_hijack_definition
FROM seg s
CROSS JOIN f
LEFT JOIN vis v  ON v.segment = s.segment
LEFT JOIN buy b  ON b.segment = s.segment
LEFT JOIN clk c  ON c.segment = s.segment
LEFT JOIN bs     ON bs.segment = s.segment
LEFT JOIN garwood g ON g.k = c.people_clicked
LEFT JOIN sg     ON sg.segment = s.segment
ORDER BY s.ord;

-- 04_conversions.sql
-- Conversions per brand and the affiliate click that gets the credit.
-- Needs bu_events (step 01), person_map and affiliate_clicks (step 03).
--
-- Tiers, read from page paths (a person can reach several):
--   purchase       order confirmation (walmart.com/thankyou, generic thank-you / order-confirmation)
--   registration   account or membership (identity.walmart.com/account/signup, Walmart+ confirmation)
--   checkout       /checkout/... past the cart, Shopify /checkouts/...
--   cart           /cart, /checkout/cart, Shopify /cart/c/...
-- Converted = purchase or registration. Checkout and cart are reported as funnel steps.
--
-- US shopping hosts only (incl. checkout.helixsleep.com and identity.walmart.com);
-- seller., business., careers., walmart.ca etc. are excluded.
-- Credit: last non-duplicate affiliate click of the same person and brand before the conversion,
-- same day (one day of data), with a same-session flag.
-- One row per person x brand x tier, first time that day.


-- name: conversion_path_discovery
-- All funnel-like paths on brand hosts, long IDs replaced by #. Used to choose the tier patterns.
WITH e AS (
    SELECT host, USER_ID,
           REGEXP_REPLACE(
               LOWER(COALESCE(REGEXP_EXTRACT(URL, '^[a-zA-Z]+://[^/?#]+(/[^?#]*)?', 1), '')),
               '/[^/]*[0-9][^/]{5,}', '/#', 'g') AS path
    FROM bu_events
    WHERE URL IS NOT NULL
      AND REGEXP_MATCHES(host, '(^|\.)(saatva|nectarsleep|helixsleep|dreamcloudsleep|walmart)\.com$')
)
SELECT host, path, COUNT(*) AS n_events, COUNT(DISTINCT USER_ID) AS n_users
FROM e
WHERE REGEXP_MATCHES(path, '(checkout|thank|confirm|order|receipt|success|complete|sign-?up|register|cart|purchase|payment)')
  AND NOT REGEXP_MATCHES(path, '^/(ip|search|browse|cp)/')          -- product / search pages that merely contain e.g. "cart"
GROUP BY host, path
QUALIFY ROW_NUMBER() OVER (PARTITION BY host ORDER BY COUNT(DISTINCT USER_ID) DESC, path) <= 30
ORDER BY host, n_users DESC, path;


-- name: build_conversion_events
-- First time each person reached each tier on each brand.
CREATE OR REPLACE TABLE conversion_events AS
WITH e AS (
    SELECT b.USER_ID, b.SESSION_ID, b.CREATED_TIME, b.host, b._ID,
           CASE
               WHEN b.host = 'saatva.com'                                     THEN 'saatva'
               WHEN b.host = 'nectarsleep.com'                                THEN 'nectar'
               WHEN b.host IN ('helixsleep.com', 'checkout.helixsleep.com')   THEN 'helix'
               WHEN b.host = 'dreamcloudsleep.com'                            THEN 'dreamcloud'
               WHEN b.host IN ('walmart.com', 'identity.walmart.com')         THEN 'walmart'
           END AS brand,
           LOWER(COALESCE(REGEXP_EXTRACT(b.URL, '^[a-zA-Z]+://[^/?#]+(/[^?#]*)?', 1), '')) AS path
    FROM bu_events b
    WHERE b.URL IS NOT NULL
),
t AS (
    SELECT *,
           CASE
               -- purchase
               WHEN host = 'walmart.com' AND REGEXP_MATCHES(path, '^/thankyou')                     THEN 'purchase'
               WHEN REGEXP_MATCHES(path, '(thank[-_]?you|order[-_]?confirm|/checkouts?/.*/(thank|success|complete|confirm))') THEN 'purchase'
               -- registration
               WHEN host = 'identity.walmart.com' AND REGEXP_MATCHES(path, '^/account/signup')      THEN 'registration'
               WHEN host = 'walmart.com' AND REGEXP_MATCHES(path, '^/plus/.*confirmation')          THEN 'registration'
               WHEN REGEXP_MATCHES(path, '^/(account/)?(register|sign-?up|create-account)(/|$)')    THEN 'registration'
               -- checkout (after the cart)
               WHEN REGEXP_MATCHES(path, '^/checkouts?(/|$)') AND NOT REGEXP_MATCHES(path, '^/checkout/cart') THEN 'checkout'
               WHEN host = 'checkout.helixsleep.com' AND REGEXP_MATCHES(path, '/checkouts/')        THEN 'checkout'
               -- cart
               WHEN REGEXP_MATCHES(path, '^/(cart|shoppingcart|checkout/cart|affil/cart)(/|$)')     THEN 'cart'
           END AS tier
    FROM e
    WHERE brand IS NOT NULL
)
SELECT t.brand, pm.person_id, t.tier,
       MIN(t.CREATED_TIME)                        AS conv_time,
       -- ties in the same second go to the smallest USER_ID, the one whose click is kept in step 03
       ARG_MIN(t.SESSION_ID, {'t': t.CREATED_TIME, 'u': t.USER_ID, 'i': t._ID}) AS SESSION_ID,
       ARG_MIN(t.USER_ID,    {'t': t.CREATED_TIME, 'u': t.USER_ID, 'i': t._ID}) AS USER_ID,
       ARG_MIN(t.path,       {'t': t.CREATED_TIME, 'u': t.USER_ID, 'i': t._ID}) AS example_path
FROM t
JOIN person_map pm USING (USER_ID)
WHERE t.tier IS NOT NULL
GROUP BY t.brand, pm.person_id, t.tier;


-- name: conversions_all_visitors
-- All visitors per brand (any channel) and how many reached each tier.
WITH visitors AS (
    SELECT b.brand, COUNT(DISTINCT pm.person_id) AS n_people_visited
    FROM bu_events b JOIN person_map pm USING (USER_ID)
    WHERE b.brand IS NOT NULL
    GROUP BY b.brand
)
SELECT v.brand, v.n_people_visited,
       COUNT(DISTINCT CASE WHEN c.tier = 'cart'         THEN c.person_id END) AS n_cart,
       COUNT(DISTINCT CASE WHEN c.tier = 'checkout'     THEN c.person_id END) AS n_checkout,
       COUNT(DISTINCT CASE WHEN c.tier = 'registration' THEN c.person_id END) AS n_registration,
       COUNT(DISTINCT CASE WHEN c.tier = 'purchase'     THEN c.person_id END) AS n_purchase,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN c.tier = 'purchase' THEN c.person_id END)
             / v.n_people_visited, 2)                                           AS pct_purchase
FROM visitors v
LEFT JOIN conversion_events c USING (brand)
GROUP BY v.brand, v.n_people_visited
ORDER BY v.n_people_visited DESC;


-- name: build_click_conversions
-- Last-click attribution: for each conversion, the last affiliate click of that person and brand before it.
CREATE OR REPLACE TABLE click_conversions AS
WITH clicks AS (
    SELECT brand, person_id, USER_ID, SESSION_ID, click_time, publisher_id, m_paid_search, m_afsrc
    FROM affiliate_clicks
    WHERE NOT is_panel_duplicate
),
pairs AS (
    SELECT c.brand, c.person_id, c.tier, c.conv_time, c.SESSION_ID AS conv_session,
           k.click_time, k.publisher_id, k.SESSION_ID AS click_session, k.m_paid_search, k.m_afsrc,
           COUNT(*)                     OVER (PARTITION BY c.brand, c.person_id, c.tier)  AS n_clicks_before,
           COUNT(DISTINCT k.publisher_id) OVER (PARTITION BY c.brand, c.person_id, c.tier) AS n_publishers_before,
           ROW_NUMBER() OVER (PARTITION BY c.brand, c.person_id, c.tier
                              ORDER BY k.click_time DESC, k.publisher_id, k.USER_ID)        AS rn
    FROM conversion_events c
    JOIN clicks k
      ON k.brand = c.brand AND k.person_id = c.person_id AND k.click_time <= c.conv_time
)
SELECT brand, person_id, tier, conv_time, click_time AS credited_click_time,
       publisher_id AS credited_publisher,
       DATE_DIFF('second', click_time, conv_time) AS seconds_click_to_conversion,
       click_session = conv_session               AS same_session,
       n_clicks_before, n_publishers_before, m_paid_search, m_afsrc
FROM pairs
WHERE rn = 1;


-- name: affiliate_conversions_by_brand
-- Affiliate clicks per brand and how many got credit for a conversion (people counted once).
WITH k AS (
    SELECT brand, COUNT(*) AS n_clicks, COUNT(DISTINCT person_id) AS n_people_clicked
    FROM affiliate_clicks WHERE NOT is_panel_duplicate GROUP BY brand
),
c AS (
    SELECT brand,
           COUNT(DISTINCT CASE WHEN tier IN ('purchase','registration') THEN person_id END)                  AS conv_people_day,
           COUNT(DISTINCT CASE WHEN tier IN ('purchase','registration') AND same_session THEN person_id END) AS conv_people_session,
           COUNT(DISTINCT CASE WHEN tier = 'purchase' THEN person_id END)                                    AS purchase_people_day,
           COUNT(DISTINCT CASE WHEN tier = 'purchase' AND same_session THEN person_id END)                   AS purchase_people_session,
           COUNT(DISTINCT CASE WHEN tier = 'registration' THEN person_id END)                                AS registration_people_day,
           COUNT(DISTINCT CASE WHEN tier = 'checkout' THEN person_id END)                                    AS checkout_people_day,
           COUNT(DISTINCT CASE WHEN tier = 'cart' THEN person_id END)                                        AS cart_people_day
    FROM click_conversions GROUP BY brand
)
SELECT k.brand, k.n_clicks, k.n_people_clicked,
       COALESCE(c.cart_people_day, 0)           AS cart,
       COALESCE(c.checkout_people_day, 0)       AS checkout,
       COALESCE(c.registration_people_day, 0)   AS registration,
       COALESCE(c.purchase_people_day, 0)       AS purchase,
       COALESCE(c.purchase_people_session, 0)   AS purchase_same_session,
       COALESCE(c.conv_people_day, 0)           AS converted_purchase_or_registration,
       COALESCE(c.conv_people_session, 0)       AS converted_same_session,
       ROUND(100.0 * COALESCE(c.conv_people_day, 0) / k.n_people_clicked, 2)   AS pct_people_converted
FROM k LEFT JOIN c USING (brand)
ORDER BY k.n_clicks DESC, k.brand;


-- name: affiliate_vs_all_visitors
-- Purchase rate: people with an affiliate click vs. everyone else. Correlation only:
-- coupon and deal sites catch people who were going to buy anyway.
WITH v AS (
    SELECT b.brand, pm.person_id
    FROM bu_events b JOIN person_map pm USING (USER_ID)
    WHERE b.brand IS NOT NULL
    GROUP BY ALL
),
aff AS (SELECT DISTINCT brand, person_id FROM affiliate_clicks WHERE NOT is_panel_duplicate),
buy AS (SELECT DISTINCT brand, person_id FROM conversion_events WHERE tier = 'purchase')
SELECT v.brand,
       CASE WHEN aff.person_id IS NOT NULL THEN 'clicked an affiliate link' ELSE 'no affiliate click' END AS segment,
       COUNT(*)                                                       AS n_people,
       COUNT(buy.person_id)                                           AS n_purchased,
       ROUND(100.0 * COUNT(buy.person_id) / COUNT(*), 2)              AS pct_purchased
FROM v
LEFT JOIN aff USING (brand, person_id)
LEFT JOIN buy USING (brand, person_id)
GROUP BY ALL
ORDER BY v.brand, segment;


-- name: conversions_by_publisher
-- Publishers that get the last-click credit.
SELECT brand, credited_publisher,
       COUNT(DISTINCT CASE WHEN tier = 'purchase' THEN person_id END)       AS purchases_credited,
       COUNT(DISTINCT CASE WHEN tier = 'registration' THEN person_id END)   AS registrations_credited,
       MEDIAN(CASE WHEN tier = 'purchase' THEN seconds_click_to_conversion END) AS median_s_click_to_purchase,
       SUM(CASE WHEN tier = 'purchase' AND n_publishers_before > 1 THEN 1 ELSE 0 END) AS purchases_with_several_publishers
FROM click_conversions
WHERE tier IN ('purchase', 'registration')
GROUP BY brand, credited_publisher
QUALIFY ROW_NUMBER() OVER (PARTITION BY brand ORDER BY COUNT(DISTINCT CASE WHEN tier = 'purchase' THEN person_id END) DESC,
                                                       credited_publisher) <= 15
ORDER BY brand, purchases_credited DESC, credited_publisher;


-- name: click_to_purchase_timing
-- Time from credited click to purchase. Seconds = the click came during checkout (see step 06).
SELECT brand,
       COUNT(*)                                                          AS n_purchases,
       SUM(CASE WHEN seconds_click_to_conversion < 60 THEN 1 ELSE 0 END)   AS under_1_min,
       SUM(CASE WHEN seconds_click_to_conversion < 600 THEN 1 ELSE 0 END)  AS under_10_min,
       SUM(CASE WHEN same_session THEN 1 ELSE 0 END)                       AS same_session,
       MEDIAN(seconds_click_to_conversion)                                 AS median_s,
       QUANTILE_CONT(seconds_click_to_conversion, 0.9)                     AS p90_s
FROM click_conversions
WHERE tier = 'purchase'
GROUP BY brand
ORDER BY brand;


-- name: dtc_affiliate_journeys
-- One row per DTC affiliate click: what the person did next that day.
--   furthest_tier         furthest funnel tier reached after the click, or 'none'
--   brand_pages_after     pages viewed on the brand site afterwards
--   completion_services   PayPal, Affirm, Klarna, Shop Pay, Attentive, Klaviyo within 60 min
--                         (widgets load on their own, so this is context, not a conversion)
--   next_mattress_site    next other mattress site visited, and seconds later
-- Hosts only, no URLs.
WITH k AS (
    SELECT brand, person_id, USER_ID, click_time, publisher_id, entry_prev_host
    FROM affiliate_clicks
    WHERE NOT is_panel_duplicate AND brand <> 'walmart'
),
after AS (
    SELECT k.brand, k.click_time, k.USER_ID, e.CREATED_TIME, e.host
    FROM k JOIN bu_events e ON e.USER_ID = k.USER_ID AND e.CREATED_TIME >= k.click_time
),
pages AS (
    SELECT a.brand, a.USER_ID, a.click_time,
           COUNT(*) FILTER (WHERE REGEXP_MATCHES(a.host, CASE a.brand
                                WHEN 'saatva' THEN '(^|\.)saatva\.com$'
                                WHEN 'nectar' THEN '(^|\.)nectarsleep\.com$'
                                WHEN 'helix' THEN '(^|\.)helixsleep\.com$'
                                WHEN 'dreamcloud' THEN '(^|\.)dreamcloudsleep\.com$' END))      AS brand_pages_after,
           STRING_AGG(DISTINCT REGEXP_EXTRACT(a.host, '(paypal|affirm|klarna|shop\.app|attentive|attn\.tv|klaviyo)', 1), ', ')
               FILTER (WHERE a.CREATED_TIME <= a.click_time + INTERVAL 60 MINUTE
                         AND REGEXP_MATCHES(a.host, '(paypal|affirm|klarna|shop\.app|attentive|attn\.tv|klaviyo)')) AS completion_services
    FROM after a
    GROUP BY a.brand, a.USER_ID, a.click_time
),
competitor AS (
    SELECT a.brand, a.USER_ID, a.click_time,
           ARG_MIN(a.host, a.CREATED_TIME)                                        AS next_mattress_site,
           DATE_DIFF('second', a.click_time, MIN(a.CREATED_TIME))                AS seconds_to_next_mattress_site
    FROM after a
    WHERE REGEXP_MATCHES(a.host, '(^|\.)(saatva|nectarsleep|helixsleep|dreamcloudsleep|purple|casper|tempurpedic|sleepnumber|'
                                 || 'brooklynbedding|birchliving|leesa|tuftandneedle|avocadogreenmattress|zinus|'
                                 || 'siena(sleep)?|awarasleep|bearmattress|nolahmattress|sealy|serta|mattressfirm)\.com$')
      AND NOT REGEXP_MATCHES(a.host, CASE a.brand
                                WHEN 'saatva' THEN 'saatva'
                                WHEN 'nectar' THEN 'nectarsleep'
                                WHEN 'helix' THEN 'helixsleep'
                                WHEN 'dreamcloud' THEN 'dreamcloudsleep' END)
    GROUP BY a.brand, a.USER_ID, a.click_time
),
tier AS (
    SELECT k.brand, k.USER_ID, k.click_time,
           MAX(CASE c.tier WHEN 'cart' THEN 1 WHEN 'checkout' THEN 2 WHEN 'registration' THEN 3 WHEN 'purchase' THEN 4 END) AS t
    FROM k JOIN conversion_events c
      ON c.brand = k.brand AND c.person_id = k.person_id AND c.conv_time >= k.click_time
    GROUP BY k.brand, k.USER_ID, k.click_time
)
SELECT k.brand, k.click_time, k.publisher_id, k.entry_prev_host,
       COALESCE(CASE t.t WHEN 1 THEN 'cart' WHEN 2 THEN 'checkout' WHEN 3 THEN 'registration' WHEN 4 THEN 'purchase' END,
                'none')                                   AS furthest_tier,
       COALESCE(p.brand_pages_after, 0)                   AS brand_pages_after,
       COALESCE(p.completion_services, '')                AS completion_services,
       COALESCE(c.next_mattress_site, '')                 AS next_mattress_site,
       c.seconds_to_next_mattress_site
FROM k
LEFT JOIN pages p      ON p.brand = k.brand AND p.USER_ID = k.USER_ID AND p.click_time = k.click_time
LEFT JOIN competitor c ON c.brand = k.brand AND c.USER_ID = k.USER_ID AND c.click_time = k.click_time
LEFT JOIN tier t       ON t.brand = k.brand AND t.USER_ID = k.USER_ID AND t.click_time = k.click_time
ORDER BY k.brand, k.click_time, k.publisher_id;

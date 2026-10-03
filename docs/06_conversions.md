# 06 · Step 04 - Conversions and Attribution

> SQL: [`sql/04_conversions.sql`](../sql/04_conversions.sql). Tested on the synthetic fixture and
> `--dev`; results are from the **full data** (one day, 2026-05-01). Counts are **people** (`person_id`,
> doc 05 §4), not user IDs. Raw outputs (`outputs/04_conversions*/`) are not committed.

---

## 1. Result

| Brand | Affiliate clicks | People | Cart | Checkout | Registration | **Purchase** | **Converted** (purchase or registration) |
|---|---:|---:|---:|---:|---:|---:|---:|
| Walmart (whole site) | 3,234 | 1,266 | 165 | 130 | 9 | **112** | **120** |
| Walmart - mattress section | 64 | 6 | 1 | 1 | 0 | **0** | **0** |
| Saatva | 4 | 4 | 0 | 0 | 0 | **0** | **0** |
| Nectar | 3 | 2 | 0 | 0 | 0 | **0** | **0** |
| Helix | 2 | 2 | 0 | 0 | 0 | **0** | **0** |
| DreamCloud | 2 | 2 | 0 | 0 | 0 | **0** | **0** |

- **Walmart:** 120 of 3,234 affiliate clicks were the last click before a conversion = **3.7% of clicks**
  (9.5% of the people who clicked). 112 purchases, 101 of them in the same session as the credited click.
- **DTC brands: 0 conversions under every conversion definition** (§2, §5). Panel counts for one day;
  scaling and confidence intervals are step 05.

## 2. Definition: four tiers

A conversion is a payment, purchase, registration or any other meaningful completion event. The data
has no event or order column, so tiers are read from page paths:

| Tier | Pages (examples from the data) | Counts as converted? |
|---|---|---|
| purchase | `walmart.com/thankyou`; generic thank-you / order-confirmation / checkout-success patterns | **yes** |
| registration | `identity.walmart.com/account/signup`, `walmart.com/plus/confirmation`, generic `/register`, `/signup` | **yes** |
| checkout | `/checkout/...` except the cart (e.g. `walmart.com/checkout/review-order`, `nectarsleep.com/checkout/shipping`), Shopify `checkout.helixsleep.com/checkouts/...` | no - funnel |
| cart | `/cart`, `/shoppingcart`, `/checkout/cart`, `/affil/cart` | no - funnel |

**Hosts:** the US shopping sites only - saatva.com, nectarsleep.com, helixsleep.com +
checkout.helixsleep.com, dreamcloudsleep.com, walmart.com + identity.walmart.com.

**Grain:** person × brand × tier, first time of the day (reloading a confirmation page counts once).

### 2.1 Pattern selection (open discovery)
`conversion_path_discovery` lists every path on the brands' hosts that looks like a funnel or completion
page (113 paths on the full data). Each path is reviewed individually. Deliberately **not** counted:

| Path | Why not |
|---|---|
| `walmart.com/orders`, `/orders/#/track` | order history: an existing order, not a new one |
| `saatva.com/order-tracker` | existing customer tracking a delivery |
| `seller.`, `business.`, `careers.`, `photos3.walmart.com`, internal Walmart hosts | not the consumer shopping site |
| `walmart.com/help/article/...` | help pages |
| `identity.walmart.com/account/phone-otp-choice/sign-up` | most likely a log-in step (borderline; 10 users) |

`/shoppingcart` and `/affil/cart` also count as cart.

## 3. Attribution

Single day of data, so no 7/30-day window. A conversion is credited to the **last** non-duplicate
affiliate click of the **same person on the same brand before it** (last click, as networks pay).
Reported for the same day and the same session.

Example: 10:00 click via `imp_150372`, 10:20 click via `imp_29332`, 10:21 `walmart.com/thankyou`:
the credit goes to `imp_29332`; the conversion row also keeps "60 s from click to purchase" and
"2 publishers before the purchase" - inputs for step 06.

## 4. Context: all visitors, and affiliate vs. non-affiliate

| Brand | People who visited | Cart | Checkout | Registration | Purchase |
|---|---:|---:|---:|---:|---:|
| Walmart (whole site) | 13,242 | 1,723 | 1,055 | 110 | **899 (6.8%)** |
| Walmart - mattress section | 53 | 11 | 8 | 0 | 5 (9.4%) |
| Nectar | 53 | 5 | 2 | 0 | 0 |
| Saatva | 31 | 0 | 0 | 0 | 0 |
| DreamCloud | 29 | 2 | 0 | 0 | 0 |
| Helix | 19 | 3 | 2 | 0 | 0 |

Walmart - mattress section = people who viewed a Walmart mattress page that day (doc 07 §5). Their cart,
checkout and purchase can be for any product: the confirmation page does not say what was bought.

| Walmart | People | Purchased |
|---|---:|---:|
| Clicked an affiliate link | 1,266 | **9.6%** |
| No affiliate click | 11,976 | **6.5%** |

Affiliate-referred people purchase ~1.5× as often. **Correlation, not causation:** deal, coupon and
cash-back publishers attract people who were about to buy anyway. Whether affiliates *cause* sales needs
a holdout / incrementality test (recommendation).

## 5. Why 0 for the DTC brands, and checks

**Nobody purchased on the four DTC sites that day, through any channel** (table above). With 19-53
visitors per site and a high-ticket, long-research product, 0 purchases in one day is the expected
outcome, not a detection failure. Checks:

1. `--dev` contains **every** DTC user, and DTC results on `--dev` and the full data are identical.
2. Open path discovery (§2.1) found no confirmation page on any DTC host.
3. Payment and financing services: PayPal appears only as button / pixel widgets loaded inside the cart
   page (`/smart/buttons`, `/web-sdk/.../pixel`), followed by more browsing; one Affirm pre-qualification;
   no completed payment.
4. Other completions (Helix quiz, e-mail / SMS sign-up via Attentive or Klaviyo): a few visitors overall,
   **none** among the affiliate clickers; a loaded widget cannot be told apart from a completed sign-up.

### 5.1 What DTC affiliate visitors did after the click (`dtc_affiliate_journeys`)

| Brand | Publisher | Came from | Furthest tier | Pages after | Next mattress site |
|---|---|---|---|---:|---|
| Saatva | mattressnrd | brooklynbedding.com | none | 2 | - |
| Saatva | mattressnrd | kotaku.com | none | 2 | - |
| Saatva | trafficpoint12345 | novilla.net | none | 2 | - |
| Saatva | brandxemail | mypillow.com | none | 11 | - |
| Helix | impact | mattressclarity.com | none | 6 | - |
| Helix | ir:1436750 | dreamcloudsleep.com | none | 1 | brooklynbedding.com (81 s) |
| Nectar | (unknown) | truemed.com | none | 13 | brooklynbedding.com (79 s) |
| Nectar | p4_resident_paid | brooklynbedding.com | none | 2 | saatva.com (20 s) |
| Nectar | (unknown) | truemed.com | none | 7 | mattressfirm.com (256 s) |
| DreamCloud | wickfire | buyersguide.org | none | 1 | sienasleep.com (94 s) |
| DreamCloud | trafficpoint-2 | sienasleep.com | none | 5 | bearmattress.com (17 s) |

0 of 11 clicks reached a funnel step; 7 of 11 moved on to a competitor, 5 within 100 seconds. The DTC
affiliate click is a **research-stage** touch; a purchase, if any, happens on a later day that a
single day of data cannot follow. **Recommendation:** measure Saatva's affiliate conversion on 30+ days
of panel data or on Partnerize's own conversion records.

## 6. Findings carried to step 06

| Signal (Walmart) | Value |
|---|---|
| Purchases less than **1 minute** after the credited click (the click happened during checkout) | **10 of 112** (9%) |
| Purchases less than 10 minutes after the click | 61 of 112; median 8 min; p90 65 min |
| `imp_29332` | 4 purchases credited, **all 4 after another publisher's click**, median **75 s** from click to purchase |
| `imp_10621` | 3 purchases, 2 after another publisher, median 65 s |
| `imp_101044` (entered from Capital One shopping / offers pages) | 8 purchases, median 3.5 min |
| `imp_150372` (largest) | 31 purchases, median 15 min, 4 after another publisher |

## 7. Validation

| Check | Result |
|---|---|
| Synthetic fixture, independent query on the raw files ("affiliate landing, later order confirmation on the same brand") | Identical purchases per brand: DreamCloud 31, Helix 33, Nectar 43, Saatva 42, Walmart 39 |
| Synthetic: `/checkout` without a trailing slash | Counted as checkout |
| Determinism | Ties between a person's duplicate IDs in the same second go to the smallest USER_ID (the ID whose click survives step 03), so "purchase in the same session" never depends on an arbitrary choice; two consecutive full runs produce byte-identical outputs |
| `--dev` vs full | DTC rows identical |

## 8. Intermediate tables

| Table | Purpose | Logic |
|---|---|---|
| `conversion_events` | One row per person × brand × tier | First event of the day on the brand's US hosts matching the tier patterns (§2) |
| `click_conversions` | Attribution | For each conversion: the last non-duplicate affiliate click of the same person and brand before it; time to conversion, same-session flag, number of clicks and publishers before |

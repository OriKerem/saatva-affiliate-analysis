# 08 · Step 06 - Attribution Hijacking: Signals, Findings, Recommendations

> SQL: [`sql/06_hijacking.sql`](../sql/06_hijacking.sql). Run on the **full data** (one day, 2026-05-01).
> Counts are non-duplicate clicks and people (doc 05). Raw outputs (`outputs/06_hijacking*/`) are not committed.

---

## 1. Definition, and how this data can see it

Attribution hijacking = organic, direct, social or paid traffic that receives an affiliate tag.
Networks pay on the **last click**, so whoever tags the visit last gets the commission.

The data has no referrer column, but the **URLs reveal the path**: the page seen just before the landing,
and the landing URL's own parameters (`gclid` / `msclkid` = paid search, `fbclid` = Facebook,
`sharedid=shopyourlikes.com` = the publisher's own site, Bizrate `rd2` redirect = comparison engine,
`afsrc=1` = stand-down requested).

Example of a Walmart affiliate landing (IDs shortened):
```
walmart.com/ip/...?clickid=X2my…&irgwc=1&afsrc=1&sourceid=imp_150372&veh=aff
                  &wmlspartner=imp_150372&affiliates_ad_id=568823&campaign_id=9383&sharedid=…
```
`sourceid` / `wmlspartner` = who gets the commission; the previous page = where the visitor really came from.
Hijacking is when the two do not fit together.

## 2. Entry path of affiliate clicks (Walmart)

| Entry path | Read from | % of clicks | People |
|---|---|---:|---:|
| Comparison engine | previous page Bizrate / Kelkoo | 37.8% | 225 |
| Other site | - | 23.6% | 635 |
| **Same site (direct / mid-visit)** | previous page = walmart.com | **16.6%** | **294** |
| Creator / influencer | Mavely, ShopYourLikes, LTK… | 11.8% | 132 |
| Cash-back / coupon | Capital One Shopping, coupon sites | 3.8% | 109 |
| **Social** | `fbclid`, social network | **3.5%** | 56 |
| **Paid search** | `gclid` / `msclkid` / ad redirect | **1.2%** | 37 |
| None / content | - | 1.7% | 54 |

DTC brands: Saatva 3 clicks from other sites + 1 paid-search-tagged; Helix and DreamCloud: one review site
each; Nectar: other sites.

## 3. Signals and evidence tiers

| Signal | Definition | Innocent explanation | Tier |
|---|---|---|---|
| S1 paid_tagged | paid-search marker on an affiliate landing | the brand allowed the affiliate to bid | **strong** - two paid channels on ONE URL |
| S4b stand-down violation | previous click had `afsrc=1`; another publisher's click < 60 s later, visitor already on the site | hardly any | **strong** |
| S5 checkout click | credited click < 60 s before the purchase | rare (a genuine coupon search) | **strong** |
| S2 social_tagged | `fbclid` on an affiliate landing | an influencer's post | possible |
| S3 mid_visit_tagged | previous page = the brand's own site | the panel logs all tabs as one timeline and does not log redirect pages | possible |
| S4 publisher switch | another publisher's click < 30 min later | comparison shopping (922 of 1,563 come from comparison engines) | context |
| S6 publisher cycling | ≥ 3 publishers for one person in one visit | creator pages with many links | context |
| S7 extension before | cash-back / coupon page or extension ≤ 10 min before | cash-back is a legitimate model | context |

**Headline measure:** the headline counts every signal that fits the hijacking definition
(strong + possible = "hijacking definition"); within it, **strong** is the conservative estimate. S4, S6, S7 are
behaviour, not "traffic that received a tag": they feed the publisher scorecard.

## 4. Results (Walmart)

| | Clicks | People (of 1,266) |
|---|---:|---:|
| **Hijacking definition** (strong + possible) | 695 (21.5%) | **380 (30.0%)** |
| **Strong** | 181 (5.6%) | **87 (6.9%)** |
| S1 paid-tagged | 39 | 36 |
| S4b stand-down violation | 132 | 43 |
| S5 checkout click | 10 | 10 |
| S2 social-tagged | 113 | 56 |
| S3 mid-visit | 537 | 294 |

**Counted by people as well as clicks**, because a few people generate most of the clicks: publisher switches
are 48% of clicks but 13% of people;
**33 people produce 78% of all switches**, mostly on comparison engines. All 132 stand-down violations
happen with the visitor already on walmart.com; none come from comparison engines.

### 4.1 Commission at risk
Of **112 purchases** credited to an affiliate (last click):

| | Purchases | % |
|---|---:|---:|
| **Strong signal** (conservative) | **14** | **12.5%** |
| - paid-tagged / stand-down violation / checkout click | 2 / 2 / 10 | |
| **Hijacking definition** (strong + possible) | **31** | **27.7%** |
| - of which mid-visit | 23 | |
| Any signal incl. extension and another publisher before (upper bound) | 57 | 50.9% |

In one sentence: "Under the hijacking definition, ~28% of Walmart's affiliate commissions that day were paid on direct, social
or paid traffic that received an affiliate tag; 12.5% carry strong evidence."

### 4.2 Two real sequences (URLs shortened)
**Stand-down violation:**
```
00:12:26  from howl.link (creator)  to walmart.com/ip/Pokemon-TCG-.../<id>?…&afsrc=1&sourceid=imp_376373…
00:12:42  from walmart.com (same page) to walmart.com/ip/tempo/<id>?…&afsrc=1&sourceid=imp_1390754…
```
A creator's click asked extensions to stand down; 16 s later another publisher's tag appears while the
visitor is still on the product page, on a generic `/ip/tempo/` URL. The credit moved to `imp_1390754`.

**Paid search + affiliate tag on one URL:**
```
walmart.com/?adid=…&wl0=e&…&wl4=kwd-…&wl14=walmart&msclkid=e147…&clickid=…&irgwc=1&sourceid=imp_150372…
```
A Bing ad click (`msclkid`, Walmart's own campaign parameters `wl*`) that also carries an affiliate tag:
the brand pays the search engine and an affiliate commission for the same visit.

### 4.3 Publisher scorecard (`publisher_risk`, ≥ 5 clicks)

| Publisher | Main entry | Clicks / people | Mid-visit | Stand-down violations | Purchases credited | Red flags |
|---|---|---|---:|---:|---:|---:|
| imp_33477 | same site | 20 / 8 | 75% | 0 | 4 (1 at checkout) | 3 |
| imp_4269889 | same site | 6 / 3 | 83% | 1 | 0 | 3 |
| imp_6810114 | same site | 6 / 3 | 67% | 2 | 0 | 3 |
| imp_6144707 | comparison | 468 / 53 (8.8 per person) | 7% | **26** | 0 | 2 |
| imp_6477652 | same site | 29 / 15 | 55% | **8** | 0 | 2 |
| imp_118767 | same site | 20 / 14 | 75% | 0 | 5 | 2 |

Flags: ≥ 5 clicks per person; ≥ 50% mid-visit; ≥ 1 stand-down violation; checkout clicks ≥ 25% of credited
purchases; ≥ 50% cycling (not counted for comparison-engine publishers); ≥ 25% after an extension; ≥ 50%
paid or social. A list to **review** with the network, not a list of proven fraudsters.

### 4.4 S1 is one publisher, not a pattern (`paid_tagged_by_publisher`)

| Publisher | S1 clicks / people | Main previous page | Via Bizrate | With `msclkid` (distinct values) | With Walmart campaign params `wl0…` |
|---|---|---|---:|---|---:|
| imp_150372 (Walmart) | **39 / 36** - all of Walmart's S1 | rd.bizrate.com | 35 | 31 (**29 distinct**) | 38 |
| src:brandxemail (Saatva) | 1 / 1 | mypillow.com | 0 | 0 (Google `gad_source=1`) | 0 |

- Every paid-tagged Walmart click belongs to **one** publisher, the comparison engine Bizrate's
  (`imp_150372`, also Walmart's top converter: 31 credited purchases).
- A paid click ID is created per ad click. 29 distinct `msclkid` values on 31 clicks = **real Bing ad
  clicks** routed through the comparison engine and tagged as affiliate, not ad parameters copied once
  into a product feed. The landings also carry Walmart's own search-campaign parameters (`wl0…wl14`).
- Two readings fit the panel equally: **arbitrage** (the affiliate buys the ad, then takes the
  commission) or an **agreed arrangement** with Walmart. A question for the network, not a verdict.
- Why it matters: S1 is concentrated, so it is **actionable** - one partner to review, not a policy for 221.

### 4.5 Walmart mattress sessions (doc 07 §5)
64 clicks from 6 people; 4 people account for 59 clicks with **8 different publishers in one visit**,
entering from creator-link services (mavely.app.link, go.sylikes.com) - publisher cycling.

## 5. Saatva and its competitors

| Brand | Click | Publisher | Came from | Signal |
|---|---|---|---|---|
| Saatva | 05:41 | mattressnrd | brooklynbedding.com | - |
| Saatva | 13:36 | mattressnrd | kotaku.com | - |
| Saatva | 14:23 | trafficpoint12345 | novilla.net | - |
| Saatva | 17:53 | **brandxemail** | mypillow.com | **S1 paid-search marker on the affiliate landing** (brand bidding) |
| DreamCloud | 03:19 | wickfire (known paid-search affiliate) | buyersguide.org | S7 coupon / cash-back activity before the click |

- **No Saatva affiliate click carries `afsrc=1`.** Impact brands (Walmart 83% of clicks, Nectar, Helix,
  DreamCloud) do. Without the flag, extensions have no standard cue to stand down - and a violation like
  §4.2 cannot even be identified.
- One day of data cannot size hijacking on Saatva (4 clicks). Walmart, the brand with volume, shows what a
  program faces: ~28% of commissions on re-tagged traffic, 12.5% with strong evidence.

## 6. Recommendations for Saatva

| # | Recommendation | Evidence here | Owner / tool |
|---|---|---|---|
| 1 | **Add `afsrc=1` to all Partnerize affiliate landings** and make stand-down a contractual rule for coupon / cash-back partners | Absent on 4/4 Saatva clicks; 132 violations measurable on Walmart *because* the flag exists | Partnerize link settings; partner T&Cs |
| 2 | **Enforce a brand-bidding policy**: no affiliate bidding on "Saatva" terms; reverse commissions on affiliate landings carrying `gclid` / `msclkid` | `brandxemail` (Saatva); 39 paid-tagged clicks on Walmart, **all from one publisher** (§4.4) - the check finds the partner to review | Partnerize Protect (search monitoring); landing-parameter rule |
| 3 | **Checkout-click rule**: no or reduced commission when the credited click is < 60 s before the order, or lands on cart / checkout | 10 of 112 Walmart purchases | Commission rules; Saatva order data |
| 4 | **Log the HTTP referrer of every affiliate landing** server-side and flag landings whose referrer is saatva.com | Mid-visit tags: 23% of Walmart's clicking people - the panel cannot settle them, Saatva's server can | Saatva web analytics |
| 5 | **Publisher scorecard, monthly**: clicks per person, switches after `afsrc`, cycling, extension share, checkout clicks | Scorecard in §4.3 | Partnerize data (complete, not a panel) |
| 6 | **Separate commission tier for coupon / cash-back** and protect content publishers (review sites drive Saatva's research-stage traffic) - e.g. fractional / multi-touch credit | Saatva's clicks come from review sites (mattressnrd); DTC visitors compare brands and buy later (doc 06 §5) | Partnerize (e.g. VantagePoint-style fractional credit) |
| 7 | **Measure properly**: 30+ days of data or Partnerize conversions for Saatva's CR; a holdout test for incrementality | 4 clicks / 0 purchases in one day; affiliate visitors buy 1.47× more on Walmart (correlation, not causation) | Analytics |

## 7. Limitations

- One day; DTC volumes too small to size hijacking per brand - Walmart is used to show the mechanics.
- A signal is a reason to look, not proof. S3 mid-visit is inflated by the panel (tabs in one timeline,
  redirect pages not logged); it is reported as "possible".
- Purchases cannot be tied to a product; "commission at risk" counts credited purchases, not order value.
- Entry-path lists were built from the data (`entry_path_discovery`); unseen publisher types fall into
  "other_site".

## 8. Intermediate tables

| Table | Purpose | Logic |
|---|---|---|
| `click_signals` | One row per non-duplicate affiliate click | Entry path (§2) + signals S1-S7 (§3) |

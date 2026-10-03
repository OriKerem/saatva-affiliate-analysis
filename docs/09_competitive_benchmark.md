# 09 · Step 07 - Competitive Benchmark: Channels, Publishers, Cross-Shopping, Scorecard

> SQL: [`sql/07_competitive_benchmark.sql`](../sql/07_competitive_benchmark.sql). Run on the **full data**
> (one day, 2026-05-01). Raw outputs (`outputs/07_competitive_benchmark*/`) are not committed.

---

## 1. Apples to apples

Saatva sells mattresses; Walmart sells everything. **Walmart is compared through its mattress section only**
(doc 07 §5: a Walmart visit that included a product, search, category, brand or sponsored page whose URL contains
"mattress"). All of Walmart appears once, in the scorecard, labelled *context only*, and is not used in any
comparison.

Segments: `saatva`, `nectar`, `helix`, `dreamcloud`, `walmart_mattress`.

## 2. Method

- **Visit** = one session on the brand's site (DTC) or a Walmart session with a mattress page. Duplicate panel
  IDs of one person (doc 05) are collapsed: one visit per (segment, person, entry time).
- **Entry channel** = how the first brand page of the visit was reached, read from the landing URL and the page
  before it. First match wins:

| Order | Channel | Rule |
|---:|---|---|
| 1 | affiliate | affiliate marker on the landing URL (doc 05) |
| 2 | paid_search | `gclid` / `gad_source` / `gbraid` / `wbraid` / `msclkid`, `utm_medium=cpc`-type, Walmart `veh=sem` / `wmlspartner=wlpa`, or an ad-server previous host |
| 3 | email | `utm_medium=email`-type, Walmart `veh=eml`, or a webmail previous host |
| 4 | social | `fbclid` / `ttclid` / `twclid`, social `utm_source`, or a social-network previous host |
| 5 | other_campaign | any other `utm_medium` |
| 6 | review_content | previous host is a review / sleep-content site (Sleep Foundation, mattressclarity, rtings, …) |
| 7 | competitor | previous host is another mattress brand or retailer |
| 8 | direct_unknown | no previous page, or the brand's own site |
| 9 | other_site | any other previous host |

- **Cross-shopping** = the same person visited another segment that day.
- **Small numbers.** 19-65 visits per segment. Shares are descriptive, not significant; the direction matters,
  not the decimals.

## 3. Channel mix (% of visits)

| Segment | Visits / people | Affiliate | Paid search | Email | Social | Other campaign | Review | From competitor | Other site | Direct |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **Saatva** | 34 / 31 | **17.6** | 11.8 | 0 | 0 | 8.8 | 2.9 | 14.7 | 32.4 | 11.8 |
| Nectar | 65 / 53 | 3.1 | **50.8** | 1.5 | 1.5 | 0 | 0 | 1.5 | 38.5 | 3.1 |
| Helix | 22 / 19 | 13.6 | 4.5 | 0 | 0 | 4.5 | 0 | 27.3 | 31.8 | 18.2 |
| DreamCloud | 32 / 29 | 6.3 | **43.8** | 0 | 0 | 9.4 | 0 | 0 | 37.5 | 3.1 |
| Walmart - mattresses | 54 / 53 | 7.4 | 37.0 | 3.7 | 0 | 0 | 1.9 | 0 | 33.3 | 16.7 |

- **Saatva has the highest affiliate share of the group (17.6%)** and one of the lowest paid-search shares. Nectar,
  DreamCloud and Walmart's mattress section buy their traffic in search (37-51%).
- Saatva and Helix receive visitors **directly from competitors' sites** (14.7% and 27.3%; for Saatva: purple.com,
  leesa.com, casper.com).

## 4. Who sends the traffic

### 4.1 Affiliate publishers

| Segment | Publishers | Clicks with `afsrc=1` | Main sources |
|---|---:|---:|---|
| **Saatva** | **3** | **0%** | mattressnrd (mattress-review publisher), brandxemail, trafficpoint |
| Nectar | 2 | 100% | truemed, paid-search affiliate |
| Helix | 2 | 100% | Impact via mattressclarity.com |
| DreamCloud | 2 | 50% | wickfire via buyersguide.org, trafficpoint |
| Walmart - mattresses | **20** | 94% | creator links (Mavely, ShopYourLikes), comparison engines (Bizrate, Kelkoo), rtings |

### 4.2 Referring sites that are not (yet) Saatva affiliates

| Site | Type | Sends to | As affiliate? |
|---|---|---|---|
| sleepfoundation.org | review / sleep content | **Saatva** | **no**: Saatva gets the visit, the site gets no commission |
| mattressclarity.com | review | Helix | yes |
| buyersguide.org | review | DreamCloud | yes |
| rtings.com | review | Walmart mattress | yes (1 click) / content (1 visit) |
| Mavely, ShopYourLikes | creator links | Walmart mattress | yes |

## 5. Cross-shopping

| Segment | People | Also visited another segment | % |
|---|---:|---:|---:|
| Saatva | 31 | 9 | 29.0 |
| Nectar | 53 | 21 | 39.6 |
| Helix | 19 | 7 | 36.8 |
| DreamCloud | 29 | 17 | **58.6** |
| Walmart - mattresses | 53 | 8 | 15.1 |

Order of same-day visits involving Saatva: **8 people visited a competitor before Saatva** (DreamCloud 4,
Helix 2, Walmart mattress 2); **2 visited one after Saatva** (Helix, Nectar). This is the order of visits
within the day, not a direct move from one site to the other. Saatva tends to be visited late in the
comparison. Median time between the visits: minutes to ~40 minutes.

## 6. Scorecard: one place

`brand_scorecard`: one row per segment, combining steps 03-07, so the results are gathered in one place.

| Segment | Site visitors | Visitors purchased | Affiliate clicks (people) | US clicks / day (95%) | Conversion | Publishers | `afsrc` | Strong hijack signal / hijacking definition (clicks) |
|---|---:|---:|---|---|---|---:|---:|---|
| **Saatva** | 31 | 0 | 4 (4) | 1,714 (467 - 4,388) | ≤ 60% of people | 3 | 0% | 1 / 1 |
| Nectar | 53 | 0 | 3 (2) | 1,285 (156 - 4,643) | ≤ 84% | 2 | 100% | 0 / 0 |
| Helix | 19 | 0 | 2 (2) | 857 (104 - 3,095) | ≤ 84% | 2 | 100% | 0 / 0 |
| DreamCloud | 29 | 0 | 2 (2) | 857 (104 - 3,095) | ≤ 84% | 2 | 50% | 0 / 0 |
| Walmart - mattresses | 53 | 5 | 64 (6) | 27,419 (10,063 - 59,678) | ≤ 46% | 20 | 94% | 0 / 10 |
| *Walmart - all (context only)* | *13,242* | *899* | *3,234 (1,266)* | *1.39 M (1.14 - 1.66 M)* | *3.7% per click* | *221* | *83%* | *181 / 695* |

## 7. Recommendations to grow Saatva's affiliate program

| # | Recommendation | Evidence | Metric to track |
|---|---|---|---|
| 1 | **Recruit review and sleep-content publishers**: Sleep Foundation (already sends Saatva visitors, unpaid), mattressclarity, buyersguide, rtings | Competitors are paid partners of exactly these sites (§4.2); Saatva's one review partner (mattressnrd) brings half its clicks | Active review publishers; share of affiliate clicks from review sites |
| 2 | **Widen the publisher base beyond 3**, starting with creator / link-in-bio networks | Walmart's mattress section uses 20 publishers, most via creator links (Mavely, ShopYourLikes) | Active publishers per month; clicks per publisher (concentration) |
| 3 | **Keep affiliates as the efficient alternative to paid search**, and protect it | Saatva: affiliate 17.6% vs paid 11.8%; Nectar / DreamCloud pay for ~45-50% of visits in search | Affiliate share of visits; cost per order vs paid search |
| 4 | **Win the comparison stage**: head-to-head content ("Saatva vs DreamCloud / Helix") with review partners; higher commission on comparison pages | 29-59% of visitors cross-shop; 8 visited a competitor before Saatva that day vs 2 after | Share of Saatva visitors arriving from comparison content |
| 5 | **Standard link hygiene: `afsrc=1` on every landing**, as competitors already do; brand-bidding rules | Saatva 0% vs Nectar / Helix 100%, Walmart mattress 94%; `brandxemail` with a paid-search marker (doc 08) | `afsrc` coverage; stand-down violations |
| 6 | **Measure on 30+ days of Partnerize data** before sizing commission changes | One day = 34 Saatva visits, 4 affiliate clicks | Conversion rate with an interval narrower than ±50% |

Hijacking recommendations (stand-down, brand bidding, checkout-click rule, referrer logging, publisher
scorecard): doc 08 §6.

## 8. Limitations

- One day and small DTC counts: shares in §3 rest on 19-65 visits per segment.
- Entry channel uses the panel's previous page; redirect pages are not logged, and tabs share one timeline
  (doc 08 §7), so some "other site" visits are really affiliate or campaign visits.
- The mattress segment depends on "mattress" appearing in the Walmart URL; a mattress product with a URL
  that does not name it is missed.

## 9. Intermediate tables

| Table | Purpose | Logic |
|---|---|---|
| `brand_visits` | One row per visit per segment | First brand page of the session; entry channel (§2); deduplicated by person and entry time |

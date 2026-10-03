# 07 · Step 05 - US Estimates and Uncertainty

> SQL: [`sql/05_us_scaling.sql`](../sql/05_us_scaling.sql), [`sql/05b_mattress_comparison.sql`](../sql/05b_mattress_comparison.sql). Tested on the synthetic fixture and
> `--dev`; results are from the **full data**. Panel counts are for **one day** (2026-05-01); estimates are
> **per day**. Raw outputs (`outputs/05_us_scaling*/`) are not committed.

---

## 1. Result

| Brand | Panel clicks | **US affiliate clicks / day** | 95% range | Panel conversions | **US conversions / day** | Conversion rate (per click; for 0, upper bound on people) |
|---|---:|---:|---|---:|---:|---|
| Walmart | 3,234 | **≈ 1.39 M** | 1.14 M - 1.66 M | 120 | **≈ 51,400** (42,800 - 61,300) | **3.7%** (2.9 - 4.9%) |
| Saatva | 4 | **≈ 1,700** | 470 - 4,400 | 0 | not measurable (§4) | ≤ 60% (0 of 4) |
| Nectar | 3 | ≈ 1,300 | 160 - 4,600 | 0 | not measurable | ≤ 84% |
| Helix | 2 | ≈ 860 | 100 - 3,100 | 0 | not measurable | ≤ 84% |
| DreamCloud | 2 | ≈ 860 | 100 - 3,100 | 0 | not measurable | ≤ 84% |

Walmart: measured, ±20%. DTC brands: an order of magnitude (hundreds to a few thousand clicks a day,
similar for Saatva and its direct competitors); conversions not measurable from one day (§4).

## 2. Scale factor

**Scale factor = US internet users ÷ panel people = 322,000,000 ÷ 751,584 ≈ 428.4**

- US internet users: **322 million**, January 2025 (93.1% of 346 million), DataReportal, *Digital 2025:
  United States of America* - https://datareportal.com/reports/digital-2025-united-states-of-america.
  The 2026 report could not be retrieved at the time of the analysis.
- Panel **people** (`person_map`, doc 05 §4), not the 783,982 user IDs. Using IDs would give a factor
  of 410.7, so every absolute estimate would be ~4% too low.
- **Assumption:** the panel is a representative sample of US internet users. The data has no weights,
  so this cannot be corrected here. Ratios (conversion rate, shares) do not depend on the factor.

## 3. Uncertainty: person-level Poisson bootstrap

- **Unit = person.** One person's clicks are correlated; resampling rows or IDs would give falsely narrow
  intervals (same idea as clustered standard errors). Duplicate IDs of one person move together.
- **Poisson bootstrap.** Resampling N people with replacement gives each person a count that is
  ~Poisson(1) for a large panel. Each person who clicked gets an independent Poisson(1) weight; people who
  did not click contribute 0 whatever their weight, so they are skipped: ~1,280 people × 1,000 replicates
  ≈ 1.3 M rows instead of 751,584 × 1,000 ≈ 750 M.
- **Deterministic.** The uniform draw is `hash(person_id, replicate) mod 10^9 / 10^9`, inverted through the
  Poisson(1) CDF. Same result on every run and with any number of threads (a seeded random generator is
  not reproducible under parallel execution).
- The panel size is treated as fixed (its own sampling error is ~0.1%).
- **Check:** bootstrap means equal the point estimates (Walmart clicks 3,236.9 vs 3,234; conversions
  120.3 vs 120). Two consecutive runs give byte-identical outputs.

## 4. Very small counts (DTC brands)

A bootstrap of 0 is [0, 0], which hides the uncertainty. Reported instead:

| Method | What | Example (Saatva) |
|---|---|---|
| Exact Poisson interval (Garwood) on the number of **people** who clicked, × clicks per person | lower = χ²(0.025; 2k)/2, upper = χ²(0.975; 2k+2)/2 | 4 people (4 clicks): 1.09 - 10.24 people, i.e. **467 - 4,388** US clicks/day |
| Exact (Clopper-Pearson) upper bound for 0 of n people | 1 − 0.025^(1/n) | 0 of 4: share converting **≤ 60.2%** |

The person is the unit because clicks are clustered in people (Nectar: 3 clicks from 2 people; Walmart
mattress sessions: 64 clicks from 6 people, §5); this is also the unit of the bootstrap.

The "rule of three" (3/n) is not used: it is a large-n approximation and exceeds 100% for n = 2 (150%).
All interval values are checked against scipy.

### 4.1 Pooling the DTC brands
The four DTC brands share category, price level and traffic type, so their zeros can be pooled:

| Population | n | Converted | 95% upper bound |
|---|---:|---:|---:|
| DTC people who clicked an affiliate link (pooled) | 10 | 0 | 30.8% |
| **All visitors of the four DTC sites, any channel** | 132 | 0 | **2.8%** |

In one sentence: "On the DTC mattress sites, the daily purchase rate was below 3% (95%)."

### 4.2 Benchmark scenario (assumption, not a measurement)
US affiliate clicks × an external conversion benchmark: **Home & Furniture, 1.29%** (orders / visits,
Dynamic Yield data for June 2026 across 400+ brands, as published by Shopify -
https://www.shopify.com/blog/ecommerce-conversion-rate). Consistent with the 2.8% bound above.
Variant: × the affiliate uplift measured in this data on Walmart (1.47 = 9.6% ÷ 6.5%, doc 06 §4).

| Brand | US clicks / day (range) | Scenario conversions / day (range) | With uplift × 1.47 |
|---|---|---|---:|
| Saatva | 1,714 (467 - 4,388) | ≈ 22 (6 - 57) | ≈ 33 |
| Nectar | 1,285 (156 - 4,643) | ≈ 17 (2 - 60) | ≈ 24 |
| DreamCloud | 857 (104 - 3,095) | ≈ 11 (1 - 40) | ≈ 16 |
| Helix | 857 (104 - 3,095) | ≈ 11 (1 - 40) | ≈ 16 |

Other sources considered and not used: IRP Commerce (UK and Ireland, no furniture category); blog
aggregators that do not name their data.

## 5. Apples to apples: mattresses vs. mattresses (`05b_mattress_comparison.sql`)

Walmart sells everything, so "all Walmart" is not comparable with four mattress brands. Walmart URLs name
the product (`/ip/<product-name>/<id>`), the search (`/search?q=...`) and the category (`/browse/...`,
`/cp/...`): a **Walmart mattress page** = product, search, category, brand or sponsored-listing page on
walmart.com whose URL contains "mattress" (accessories kept: the DTC brands sell them too). A Walmart
affiliate click is in the **mattress segment** if its visit included a mattress page.

| Segment | Site visitors | Visitors who purchased (any channel) | Affiliate clicks (people) | Clicks credited with a conversion | US affiliate clicks / day (95% range) | Conversion |
|---|---:|---:|---:|---:|---|---|
| Saatva | 31 | 0 | 4 (4) | 0 | 1,714 (467 - 4,388) | ≤ 60% of people |
| Nectar | 53 | 0 | 3 (2) | 0 | 1,285 (156 - 4,643) | ≤ 84% |
| Helix | 19 | 0 | 2 (2) | 0 | 857 (104 - 3,095) | ≤ 84% |
| DreamCloud | 29 | 0 | 2 (2) | 0 | 857 (104 - 3,095) | ≤ 84% |
| **Walmart - mattresses** | **53** | 5 | **64 (6)** | 0 | 27,419 (10,063 - 59,678) | ≤ 46% |
| Walmart - all | 13,242 | 899 | 3,234 (1,266) | 121 | 1.39 M (1.14 M - 1.66 M) | 3.7% per click |

- **Mattress shoppers are few everywhere.** Walmart's mattress pages had **53 visitors** that day -
  the same order as Nectar (53) and Saatva (31). The 1.39 M Walmart affiliate clicks are almost all
  non-mattress products; "all Walmart" is the wrong benchmark for Saatva.
- 5 of the 53 Walmart mattress visitors purchased something that day (the confirmation page does not say
  what), none credited to a mattress-session affiliate click.
- **64 clicks from only 6 people:** 4 people account for 59 clicks, each with **8 different publishers in
  one visit**, entering from creator-link services (mavely.app.link, go.sylikes.com). Carried to step 06.
- Walmart "121 clicks credited" vs. "120 people converted" (doc 06): one person's purchase and
  registration were credited to two different clicks.
- Intervals: person-level bootstrap for > 10 people, exact Poisson on people × clicks per person for ≤ 10
  (clicks are clustered in people).

## 6. Intermediate tables

| Table | Purpose | Logic |
|---|---|---|
| `person_brand` | One row per (brand, person who clicked) | Non-duplicate clicks; converted / purchased credited by last click (doc 06) |
| `bootstrap_reps` | 1,000 replicates × brand | Sum of Poisson(1)-weighted clicks, conversions, purchases |
| `walmart_mattress_pages` | Walmart mattress page views | walmart.com product / search / category / brand / sponsored pages whose URL contains "mattress" |
| `segment_clicks` | Clicks per comparison segment | DTC brands, Walmart all, Walmart mattress-session clicks |
| `segment_bootstrap` | 1,000 replicates × segment | Same Poisson bootstrap as `bootstrap_reps` |

# 01 · Problem Breakdown & Methodology

> Scope: metric definitions, identification logic, extrapolation, fraud indicators and pipeline.
> The data facts these choices rest on are in doc 02.

---

## 1. The business question and the decision it serves

**Client:** Saatva (premium DTC mattress brand), via its affiliate program.

| Question | Decision it feeds |
|---|---|
| How does Saatva's affiliate program perform vs. Nectar, Helix, DreamCloud, Walmart? | Where to invest: more publishers, different publisher types, or better conversion? |
| Where is it underperforming? | Which lever to pull first (traffic volume vs. conversion vs. publisher mix) |
| How can it reduce fraudulent clicks (attribution hijacking)? | Which publishers to audit, and which commission rules to change |

The analysis therefore has to end in **ranked, actionable recommendations**, not only a benchmark table.

### Core outputs per brand
1. Estimated number of **affiliate clicks** in the **US** during the period.
2. How many of those clicks **resulted in a conversion**.

From these two numbers everything else is derived:

```
Affiliate conversions = Affiliate clicks × Click-to-conversion rate
Affiliate clicks      = Active publishers × Clicks per publisher
```

This driver tree tells us *why* Saatva is behind or ahead, not only *that* it is.

---

## 2. Metric definitions (numerator, denominator, grain, window, exclusions)

| Metric | Definition | Grain | Notes / exclusions |
|---|---|---|---|
| **Affiliate click** | An arrival on a brand domain that carries an affiliate marker (landing parameter + value). A preceding hit on an affiliate-network redirect domain is a secondary check (redirect pages are almost never logged, doc 03) | One click per user × brand × publisher, with a 30-min merge; panel duplicates (same per-click ID, or same whole-day fingerprint in the same second) are flagged; counts are of **people** (`person_id`), not user IDs | Redirect chains, reloads and back-navigations produce several rows for one real click - they are collapsed. The panel logs some people under several IDs (4.1% of IDs on the full data, doc 05) |
| **Conversion** | A visit to an order-confirmation / thank-you page on the brand domain (including checkout subdomains, e.g. `checkout.helixsleep.com`), or another completion event: payment, **registration** | One per user × brand × order page (deduplicated) | Read from page paths in four tiers: purchase and registration = converted; checkout and cart = funnel. Cart/checkout *starts* are **not** conversions; they are a funnel step |
| **Converting affiliate click** | An affiliate click that is the **last** affiliate click by the same person to that brand before a conversion, within the attribution window | Click | Last-click logic mirrors how affiliate commissions are paid in practice |
| **Attribution window** | **Same session** and **same day** | - | The data covers a single day, so multi-day windows (7, 30 days) cannot be measured |
| **Click-to-conversion rate (CR)** | Converting affiliate clicks ÷ affiliate clicks | Brand | Reported with a confidence interval (person-level bootstrap), or an exact upper bound when no conversion is observed |
| **Affiliate share of traffic** | Affiliate clicks ÷ all sessions landing on the brand | Brand | Shows how dependent each brand is on the channel |

**Why deduplication matters:** a single real click typically appears as 2-4 rows in clickstream
(network redirect, then landing, then reload). Without collapsing them, clicks are inflated and CR is deflated.

---

## 3. How to identify affiliate traffic in clickstream (the hardest step)

There is **no referrer column**. We reconstruct the path ourselves by ordering each user's events
in time (`LAG()` over `USER_ID` / `SESSION_ID` ordered by `CREATED_TIME`).

Two complementary signals:

**A. Parameters on the landing URL (brand domain).** Affiliate networks append click IDs, e.g.

| Network | Typical markers |
|---|---|
| Impact | `irclickid`, `irgwc`, `im_ref`, `sharedid`, `clickid` |
| CJ | `cjevent`, `cjdata` |
| Rakuten | `ranMID`, `ranEAID`, `ranSiteID` |
| Awin / ShareASale | `awc`, `sscid`, `sas` |
| Partnerize | `clickref` (on landing). `camref` lives in the redirect path `prf.hn/click/camref:…`, not on the landing |
| Generic / brand-defined | `utm_medium=affiliate`, `utm_source=<publisher>`, `aff_id`, `affid`, `ref`, `veh=aff`, `sourceid=imp_` (Walmart) |

**B. Hits on affiliate redirect domains just before landing.** e.g. `prf.hn`, `sjv.io`, `pxf.io`,
`7eer.net`, `anrdoezrs.net`, `jdoqocy.com`, `tkqlhce.com`, `dpbolvw.net`, `kqzyfj.com`,
`click.linksynergy.com`, `awin1.com`, `shareasale.com`, `go.skimresources.com`, `howl.me`, `avantlink.com`.
Signal B is a secondary check: the panel almost never logs redirect pages (doc 03 §5.1), so
identification relies on landing parameters and their values (signal A).

> **Source of the lists above:** a starting point from general knowledge of how the major networks tag
> clicks. Only the Partnerize entries (Partnerize's own docs) and the Impact domains (brand pages) are
> backed by the public sources in doc 00; the rest
> are unverified. Generic keys (`ref`, `clickid`) are high false-positive risk. None of these lists is
> used as-is - they are seeds for the data-driven discovery below.

**Approach: build the dictionary from the data, not from memory.**
1. Extract every query-parameter key seen on each brand's URLs; rank by frequency.
2. Classify each key manually (affiliate / paid search / email / internal / noise) and save it as a
   versioned lookup table (`sql/ref_param_classification.csv`).
3. Cross-check with signal B: arrivals preceded by a known network domain should carry an affiliate
   key. Disagreements reveal missing keys.

Signal A + B together also give us the **publisher**: the page the user saw *before* the network
redirect (or the `utm_source` / publisher ID in the URL).

---

## 4. How to identify conversions

1. List URL paths per brand that contain words like `confirm`, `thank`, `success`, `receipt`,
   `order-complete`, `checkout`.
2. Inspect the top paths manually and select the true post-purchase page for each brand.
3. Store the chosen patterns in a lookup table, one row per brand, with an example URL as evidence.
4. Validate: a confirmation page should almost always be preceded by a checkout page in the same
   session. A low share is a red flag for the pattern.

Paths are classed in four tiers - purchase and registration (converted), checkout and cart (funnel).
The DTC brands have no purchases on the observed day, so the funnel tiers are reported too (doc 06).
Attribution is last-click to the same person's affiliate click on the same brand, same day / same session.

**Walmart caveat (apples to oranges):** a Walmart conversion can be any product. Two views:
- *All Walmart* (the brand as a whole), and
- *Walmart mattress section* - visits that include a walmart.com product / search / category / brand /
  sponsored page whose URL contains "mattress" (doc 07 §5).
The second is the comparison used for Saatva; all Walmart is shown as context only.

---

## 5. From a sample to "the US"

Scope: the data is a panel sample; the goal is **estimated US** numbers.

**Problem 1: no country column.** Options, in order of preference:
1. Check whether URLs/subdomains reveal locale (e.g. `.co.uk`, `/en-gb/`, `walmart.ca`) and exclude
   non-US traffic.
2. Use timezone of activity (hour-of-day profile in UTC) as a sanity check that users behave like a
   US population.
3. State explicitly: *"The panel is assumed to be US-based."*

**Problem 2: scaling.** A clickstream panel captures a fraction of users. Scaling factor:

```
scale = US online population / distinct users in the sample
Estimated US clicks = sample clicks × scale
```

- US online population is an external input: 322 M US internet users (DataReportal, January 2025);
  the denominator is panel **people**, not user IDs (doc 07 §2).
- **Ratios (CR, shares, rankings) do not depend on the scale factor**; only absolute volumes do.
  So the comparison between brands is robust even if the scale is wrong.
- Uncertainty: **person-level Poisson bootstrap** (resampling people, not rows), because rows from the
  same person are correlated; exact intervals for very small counts (doc 07 §3-4).

**Known panel biases to state:** browser-extension panels over-represent desktop and specific
demographics; mobile-app purchases are missing. These bias absolute numbers more than comparisons.

---

## 6. Competitive analysis (what we compare)

1. **Volume:** estimated US affiliate clicks per brand (with CI).
2. **Efficiency:** CR per brand (with CI or an exact upper bound), and time from click to conversion.
3. **Dependence:** affiliate share of each brand's visits, next to paid search, email, social, review
   sites and competitor sites (channel mix, doc 09 §3).
4. **Publisher mix:** number of publishers and their type - content/review, coupon/cashback, creator,
   comparison engine, paid search - and stand-down coverage (`afsrc`).
5. **Publisher gaps:** review and content sites that send traffic to competitors as affiliates, or to
   Saatva without an affiliate relationship: a concrete recruitment list (doc 09 §4.2).
6. **Cross-shopping:** how many visitors also visit a competitor the same day, and in which direction.

Multiple comparisons: with five brands and several metrics, we focus on effect sizes with CIs
rather than a long list of p-values.

---

## 7. Fraud: attribution hijacking

**Mechanism:** a malicious extension / malware sees the user heading to saatva.com (from Google,
by typing the URL, or from a paid ad) and silently inserts an affiliate redirect, so the publisher
takes credit for a sale it did not cause.

**What it looks like in clickstream.** Each affiliate click is read through its entry path (the
previous page of the same person) and its landing parameters:

| # | Signal | Why it signals hijacking | Evidence tier |
|---|---|---|---|
| S1 | **Paid-search and affiliate markers together** (`gclid` / `gad_source` / `msclkid` + affiliate ID) | Paid traffic re-tagged as affiliate | strong |
| S4b | **Stand-down violation:** a click with `afsrc=1`, then another publisher's tag < 60 s later on the brand site | The flag exists precisely to prevent this | strong |
| S5 | **Checkout click:** the credited click < 60 s before the purchase | Credit taken at the end of the journey | strong |
| S2 | **Social marker** (`fbclid`) on an affiliate landing | Social traffic re-tagged (or a creator's post) | possible |
| S3 | **Mid-visit tag:** previous page is the brand's own site | Tag inserted while the visitor is already shopping | possible |
| S4, S6, S7 | Publisher switch, publisher cycling, extension page before the click | Behaviour; used for the publisher scorecard | context |

Redirect hops and search pages are not in the data (doc 03 §5.1-5.2), so indicators that need them
(no publisher page before the redirect, sub-second redirect gap, brand-term search before the redirect)
are not used. Full definitions and results: doc 08 §3-4.

**Output:** the share of clicks and of credited purchases with a signal in each tier (commission at
risk), and a per-publisher scorecard of red flags, so publishers can be ranked by risk × commission at
stake. Coupon/cashback extensions sit in a gray zone (legitimate publishers with extension-driven
last-touch activation) and are reported as context rather than labeled fraud.

**Recommendations are rule-based and testable**, e.g. no commission for clicks that occur after
the user reached checkout; publisher audits for the scorecard's top offenders; an incrementality holdout for
the gray-zone publishers.

---

## 8. Correlation vs. causation - what this data can and cannot say

- Higher CR for a competitor's coupon publishers ≠ those publishers *cause* more sales; coupon users
  are already deep in the funnel (selection bias).
- Affiliate clicks ≠ incremental sales. Measuring incrementality needs an experiment
  (publisher holdout or geo test) - proposed as the next step, not claimed.

---

## 9. Pipeline & efficiency plan

**Stack:** DuckDB (SQL directly on Parquet, columnar, no load step) orchestrated from Python.
SQL is the primary deliverable.

| Step | File | Output |
|---|---|---|
| 00 | `sql/00_stage.sql`, `sql/00_profile.sql` | Parquet read once into `stg_events`; data quality report (doc 02) |
| 01 | `sql/01_param_discovery.sql` | Brand users' journeys (`LAG` / `LEAD`); parameters and entry pages per brand (doc 03) |
| 02 | `sql/02_param_values.sql` | Decisive parameter values; network and search-page presence (doc 03) |
| 03 | `sql/03_affiliate_clicks.sql` | Affiliate clicks with publisher; panel duplicates; `person_map` (doc 05) |
| 04 | `sql/04_conversions.sql` | Conversion tiers; last-click attribution (doc 06) |
| 05 | `sql/05_us_scaling.sql`, `sql/05b_mattress_comparison.sql` | US estimates with bootstrap / exact intervals; Walmart mattress segment (doc 07) |
| 06 | `sql/06_hijacking.sql` | Entry paths, signals S1-S7, commission at risk, publisher scorecard (doc 08) |
| 07 | `sql/07_competitive_benchmark.sql` | Channel mix, publishers, cross-shopping; **one scorecard table, all brands** (doc 09) |
| - | `src/run_pipeline.py` | Runs the SQL blocks in order; run modes full / `--subset` / `--dev` / synthetic |

**Efficiency practices:**
- Develop on a **user-level subset** (`hash(USER_ID) % 20 = 0`), not a random row sample - a row sample
  breaks sessions and click-to-conversion paths.
- A second, **stratified dev sample** (`--dev`): every user who touched a DTC brand + all Walmart
  mattress shoppers + random 5% of the rest + the panel copies of those random-5% users. The random 5%
  holds only 1-3 users per DTC brand (doc 02), too few to validate logic, and a user-ID sample misses
  duplicate pairs (doc 04 §5.1). `--dev` is used to validate logic only, never for rates.
- Filter early to brand domains + affiliate network domains + search pages; the long tail of the
  web is never joined.
- Every step from 02 on is validated on `--dev`/`--subset` before the full run.

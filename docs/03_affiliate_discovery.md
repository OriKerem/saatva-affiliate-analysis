# 03 · Step 01 - Affiliate Signal Discovery: Results

> Run: `python src/run_pipeline.py --steps 01` on the **full dataset** (32 Parquet files, one day:
> 2026-05-01 UTC). Runtime ≈ 1.5 min. SQL: [`sql/01_param_discovery.sql`](../sql/01_param_discovery.sql).
> Raw outputs (`outputs/01_param_discovery/`) are **not committed**: they contain sample URLs from the
> panel. This document publishes the aggregated findings and the decisions they lead to.

---

## 1. Purpose

Build the affiliate dictionary (which URL parameters and domains mark an affiliate click, per brand)
**from the data**, instead of from the seed lists in docs 00/01. Approach: *open discovery* - list
everything that appears on each brand's URLs and right before each brand landing, then identify
which network each signal belongs to. A checklist search would only find what we already assumed.

## 2. Subset-first validation: samples and checks

The logic is validated on a synthetic fixture and on two samples of the real data, and the full run
is compared against them. On the synthetic fixture the SQL recovers every planted parameter and
redirect domain.

**Why two samples.** The random 5% user subset holds only 1-3 users per DTC brand (doc 02) - too few
to validate DTC logic. A second, stratified sample (`--dev`) keeps **every** user who touched a DTC
brand, every Walmart mattress shopper, a random 5% of everyone else and the panel copies of those
random-5% users (doc 04 §5.1). It is used to validate logic, never for rates.

### 2.1 Random 5% subset (`--subset`) - are the signals stable?

| Walmart signal | Full: users | Subset: users | Subset / full |
|---|---:|---:|---:|
| `wmlspartner` | 4,704 | 217 | 4.6% |
| `veh` | 4,136 | 190 | 4.6% |
| `irgwc` | 1,310 | 58 | 4.4% |
| `afsrc` | 945 | 46 | 4.9% |
| `affiliates_ad_id` | 1,304 | 56 | 4.3% |
| `walmart.com` users | 13,926 | 687 | 4.9% |

Every ratio is close to the expected 5%, and 14 of the 15 most frequent Walmart parameters are the
same in both runs, so the method finds the same signals on a random sample. For DTC brands the subset
holds 1 user each (Helix: 0) and **no affiliate marker at all**, confirming the need for `--dev`.

### 2.2 Stratified dev sample (`--dev`) - exact check for DTC brands

`--dev` keeps 1,103 brand users and 251,285 events in the step-01 working set (full data: 16,063 users,
2,246,751 events, ~9× more). Because every DTC user is included, DTC results must equal the full run:

| Check | Result |
|---|---|
| DTC brand × parameter rows (users and rows) | 113 rows, **0 differences** |
| Users on DTC main sites (Saatva 32, Nectar 57, DreamCloud 30, Helix 20) | Identical |
| Entries into DTC sites (42 / 85 / 43 / 46) | Identical |
| Walmart | partial by design (random 5% + mattress shoppers + panel copies) |

Cost control: only one full scan per run (the user filter); everything else runs on the reduced set.

## 3. Intermediate tables (purpose and logic)

| Table | Purpose | Logic | Size (full data) |
|---|---|---|---|
| `brand_users` | Restrict all later work to relevant users | Distinct `USER_ID` whose `SUBDOMAIN` **or** `URL` contains a brand token (`saatva`, `nectarsleep`, `helixsleep`, `dreamcloudsleep`, `walmart`). URL match also catches redirect URLs carrying the destination | 16,063 users |
| `bu_events` | Reconstruct journeys (there is no referrer column) | All events of `brand_users`; host = URL host, lower-cased, `www.` stripped (fallback `SUBDOMAIN`); `brand` set **only** for the main US shopping site; `LAG`/`LEAD` over `USER_ID` ordered by `CREATED_TIME, _ID` give previous/next host, URL, session and gap in ms | 2,246,751 events, of which 129,401 on brand main sites |

Both live in `data/intermediate/analysis.duckdb` (git-ignored, rebuilt by the pipeline).
`brand_users` and the host/brand columns are built once in the staging step (`sql/00_stage.sql`,
doc 04); step 01 reads `stg_events`. The regression comparison in doc 04 §3 confirms identical results.

## 4. Results

### 4.1 Traffic to each brand's main site (full data, one day)

| Brand | Users | Events | Domain notes |
|---|---:|---:|---|
| Walmart | 13,926 | 128,982 | 375 Walmart-related hosts; non-US (`walmart.ca`, 95 users) to exclude |
| Nectar | 57 | 182 | `nectarsleep.co.uk` (1 event) to exclude |
| Saatva | 32 | 82 | `saatva.prf.hn` (Partnerize branded domain, 1 user). `saatvadreams.com`, `saatvamattress.com` not found |
| DreamCloud | 30 | 90 | - |
| Helix | 20 | 65 | **`checkout.helixsleep.com`** (3 users): checkout lives on a subdomain, so it must be included for conversions |

### 4.2 What an affiliate landing looks like, per brand

| Brand | Markers found on the landing URL | Network | Users with marker |
|---|---|---|---:|
| Saatva | `utm_medium=affiliate` + `click_id=1101l…` (often with `coupon`, sometimes `app_clickref`) | Partnerize | 7-10 |
| Helix | `irclickid`, `irgwc=1`, `afsrc=1`, `ir_partnerid`, `ir_adid`, `ir_campaignid` | Impact | 4 |
| Nectar | `CIDIMP`, `irgwc=1`, `afsrc=1`, `utm_campaign=IMPACT` | Impact | 2 |
| DreamCloud | `CIDIMP`, `irgwc=1`, `afsrc=1`, `utm_campaign=IMPACT`, `utm_medium=AFF` | Impact | 2 |
| Walmart | `irgwc=1`, `afsrc=1`, `veh=aff`, `wmlspartner=imp_…`, `clickid`, `affiliates_ad_id`, `sharedid`, `campaign_id` | Impact | ≈ 1,300 |

"Users with marker" = users who saw the marker on any brand-site URL. These are not deduplicated
clicks, and parameter **values** are checked separately (see §6, §8).

Example (IDs truncated): `saatva.com/mattresses/…?utm_medium=affiliate&click_id=1101l…&coupon=…`;
`dreamcloudsleep.com/mattress?CIDIMP=…&irgwc=1&afsrc=1&utm_campaign=IMPACT&utm_medium=AFF`.

### 4.3 Expected (docs 00/01) vs. found

| Expected | Found | Verdict |
|---|---|---|
| Saatva: Partnerize, `clickref` on landing | Partnerize confirmed; the landing parameter is **`click_id`**, not `clickref`. Value format `1101l…` resembles Partnerize IDs | Network confirmed, parameter different |
| Nectar, Helix: Impact | Confirmed (`irgwc`, `afsrc`; Helix also `irclickid`) | Confirmed |
| DreamCloud: network unknown | **Impact**, identical format to Nectar (same parent company) | Discovered |
| Walmart: `veh=aff`, `sourceid` | Found; `affiliates_ad_id` also exists | Confirmed |
| Walmart: `goto.walmart.com` redirect | Not found | Not in the data |
| Impact: `im_ref`; CJ `cjevent`; Rakuten `ranMID`; Awin `awc`; ShareASale `sscid`; generic `aff_id` | Not found on any DTC brand | Not in the data |
| Redirect domains before landing (`prf.hn`, `sjv.io`, `pxf.io`, CJ domains, `awin1.com`, `go.skimresources.com`) | **None** appears right before a DTC landing (see §5.1) | Not in the data |
| - (not anticipated) | `afsrc=1` stand-down flag on Impact landings; absent on Saatva (§4.4) | Discovered |
| VigLink, Rakuten | Only lead to Walmart (5 and 2 users) | Marginal |

### 4.4 `afsrc=1` - a parameter we did not anticipate, relevant to fraud

`afsrc=1` was not in any seed list. It is the industry **stand-down** flag: it tells browser
extensions (coupon / cashback / toolbars) that an affiliate already referred this visit, so they
should not activate their own affiliate link and overwrite the credit
([PIE](https://blog.pie.org/afsrc-1-a-simple-option-for-consistent-stand-down-in-affiliate-marketing/)).

| | Nectar | DreamCloud | Helix | Walmart | Saatva |
|---|---:|---:|---:|---:|---:|
| Users with `irgwc` (Impact click) | 2 | 2 | 4 | 1,310 | - |
| Users with `afsrc` | 2 | 1 | 4 | 945 | **0** |

- On the Impact brands, `afsrc=1` travels with the affiliate click (Walmart: 945 users with `afsrc` vs. 1,310 with `irgwc`, about 70% as many).
- **Saatva's Partnerize landings carry no `afsrc`.** Hypothesis (n = 7-10 users, not conclusive):
  Saatva's affiliate links do not signal stand-down, so extensions have no standard cue to stay out
  - which would leave the program more exposed to the overwriting behaviour this analysis defines
  as attribution hijacking.
- Usable as an indicator: an affiliate landing **with** `afsrc=1` followed shortly by a landing
  with a **different** affiliate tag = a stand-down violation.

### 4.5 Paid search is the dominant *tagged* traffic for Nectar and DreamCloud

Nectar landings with `utm_medium=cpc`, Resident's internal `rh_*` parameters and `gclid`: ≈ 34 users
(vs. 2 with affiliate markers). Same pattern for DreamCloud (`rh_*`, `gclid`: ≈ 13-15 users).

### 4.6 Walmart: intermediaries before entry

Most frequent hosts right before a Walmart entry include `rd.bizrate.com` (255 users),
`mavely.app.link` (104), `walmrt.us`, `s.golikely.com`, `w-mt.co`, `go.sylikes.com`, `rstyle.me` -
price-comparison and creator/influencer link services. Step 06 classifies them as comparison or
creator traffic (doc 08); `walmrt.us` and `w-mt.co` are short links whose owner is not visible
and stay unclassified.

## 5. Data properties and their consequences

### 5.1 Network redirect pages are almost never logged
`prf.hn` appears once in the whole dataset (`saatva.prf.hn`); no network domain precedes a DTC landing.
The panel appears to record the final page, not intermediate redirects.
So: **Signal B (redirect hit) is demoted to a secondary check; identification relies on landing
parameters (signal A).** Hijack indicators do not rely on a redirect hop (doc 08 §3).

### 5.2 Search pages do not appear before brand entries
No `google.com` / `bing.com` page precedes any brand entry (only `clickserve.dartsearch.net`, a
Google Ads redirect), and `google.com` was not among the top domains in profiling.
The panel excludes search-engine result pages (confirmed in §8.5: 23 Google search pages in 48.4 M events).
So a brand-term search before an affiliate redirect cannot be observed. Paid-search traffic is
identified by parameters instead (`gclid`, `gad_source`, `gclsrc`) - which also enables a direct test
of the hijacking definition used in this analysis: **paid-search markers and affiliate markers on the same landing**.

### 5.3 DTC affiliate volume is tiny
7-10 Saatva users, 4 Helix, 2 Nectar, 2 DreamCloud in a full day of panel data.
So confidence intervals are very wide; DTC comparisons can only be directional. This is a
finding in itself and is reported as such.

## 6. Limitations of this step

- Output tables are capped (top 60 parameters / top 40 previous hosts per brand / top 100 network
  rows). DTC brands are below the caps, so their "not found" is reliable; **Walmart's is not**.
- Counts are users who saw a parameter, not deduplicated clicks.
- Parameter **names** only; values are checked in step 02, §8 (e.g. `wmlspartner=wlpa` co-occurs with
  Google Ads markers = not affiliate).

## 7. Decisions

| # | Decision | Reason |
|---|---|---|
| 1 | Identify affiliate clicks by **landing parameters + values** per brand | §5.1 |
| 2 | A focused, uncapped check of parameter values (`utm_medium`, `veh`, `wmlspartner`, `sourceid`), of every seed parameter/domain and of search-engine pages (§8) | §5.2, §6 |
| 3 | Include `checkout.helixsleep.com` and other checkout/account subdomains when identifying conversions | §4.1 |
| 4 | Define "conversion" broadly: purchase, payment, **registration** or other completion event | Analysis scope |
| 5 | Hijack indicators without a redirect-hop dependency: paid-search + affiliate co-occurrence, and an affiliate tag appearing mid-session on the brand site (doc 08 §3) | §5.1, §5.2 |
| 6 | Classify Walmart intermediaries (Bizrate, Mavely, LTK `rstyle.me`, …) as publisher types | §4.6 |
| 7 | A stand-down indicator: `afsrc=1` landing followed by a different affiliate tag; `afsrc` coverage measured across all of Saatva's affiliate landings | §4.4 |

---

## 8. Step 02 - focused checks (`sql/02_param_values.sql`)

Validated on `--dev` and `--subset` (search-domain patterns anchored on whole labels, doc 04 §6.2) and
run on the full data. DTC results on the full data equal `--dev` exactly (84 brand × parameter ×
value rows, 0 differences).

### 8.1 Parameter **values** decide affiliate vs. not (Walmart, full data)

| Parameter | Value | Users | Meaning |
|---|---|---:|---|
| `veh` | `aff` | 1,315 | **Affiliate** |
| `veh` | `sem` / `sem_lia` | 2,051 / 374 | Paid search / local inventory ads |
| `veh` | `dsn` | 613 | Display |
| `veh` | `eml` | 102 | Email |
| `wmlspartner` | `imp_…` | 1,310 | **Affiliate (Impact)** |
| `wmlspartner` | `wlpa…` | 2,685 | Paid search / shopping ads |
| `sourceid` | `imp_…` | 1,312 | **Affiliate (Impact)** |

`veh=aff`, `wmlspartner=imp_…`, `sourceid=imp_…` and `irgwc=1` agree (1,310-1,315 users): four
independent markers point to the same affiliate population. A parameter *name* alone would have
mixed affiliate with 2,000+ paid-search users.

Also notable on Walmart: `utm_source=chatgpt.com` on **127 users** - AI-assistant referrals, the
"zero-click" channel; and `utm_source=katalys` (a performance/affiliate network, 14 users).

### 8.2 DTC brands: values (exact, full data = `--dev`)

| Brand | Affiliate markers | Other tagged traffic |
|---|---|---|
| Saatva | `utm_medium=affiliate` (7 users); Partnerize `click_id` prefixes `1101l…` (5), `1100l…` (4), `1011l…` (1); publishers in `utm_source`: `mattressnrd` (likely Mattress Nerd, a review site, 4), `trafficpoint12345` (2) | `utm_medium=streaming` (`tatari`, TV attribution, 2) |
| Helix | `utm_source=impact` + `irclickid` (4) | - |
| Nectar | `utm_medium=aff` / `utm_campaign=impact` (1-2) | `utm_medium=cpc`, `utm_source=google` (**34**) |
| DreamCloud | `utm_medium=aff` / `utm_campaign=impact` (2); `utm_source=trafficpoint-2`, `wickfire` (1 each) | `utm_medium=cpc` (**15**) |

`trafficpoint` appears at both Saatva and DreamCloud. `wickfire` is known as a paid-search affiliate
(buys search ads on behalf of brands) - relevant to the hijacking definition used here, which includes
paid search traffic re-tagged as affiliate.

### 8.3 Uncapped presence of every seed parameter (full data)

CJ (`cjevent`, `cjdata`), Rakuten (`ranmid`, `raneaid`, `ransiteid`), Awin (`awc`), ShareASale
(`sscid`, `sas`), Partnerize `clickref` / `camref`, Impact `im_ref`, generic `aff_id` / `affid`:
**0 users on every brand, including Walmart.** This uncapped check confirms the step-01 "not found"
for Walmart (step 01 is capped at 60 keys).

### 8.4 Seed redirect domains anywhere in brand users' journeys (full data)

Network redirect pages *are* logged occasionally (e.g. `iherb.prf.hn` to `iherb.com`), but very few lead
to our brands: VigLink to Walmart 9 users, Impact to Walmart 8, Rakuten / CJ / AvantLink / Howl to Walmart
1-2 each, **none to any DTC brand**. Confirms §5.1: identification must rely on landing parameters.

### 8.5 Search-engine result pages are absent

In all 48.4 M events: **23 Google search pages (4 users)** and 9 DuckDuckGo search pages. Other Google
pages exist (Translate 158 users, Accounts 1,147 users), so this is not a parsing error - the panel
excludes search-result pages. H5 (brand-term search followed by an affiliate click) cannot be measured; paid search is
measured through `gclid` / `gad_source` / `msclkid` / `veh=sem` instead.

Data-quality footnote: a few hosts carry an invisible U+200E character or typos
(`‎safe.duckduckgo.com`, `wwww.google.com`); negligible volume, noted for completeness.

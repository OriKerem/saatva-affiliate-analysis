# 05 · Step 03 - Affiliate Clicks per Brand

> SQL: [`sql/03_affiliate_clicks.sql`](../sql/03_affiliate_clicks.sql). Tested on the synthetic
> fixture, `--dev` and `--subset`; results are from the **full data** (one day, 2026-05-01).
> Raw outputs (`outputs/03_affiliate_clicks*/`) are not committed: `click_examples` holds full panel URLs.
> All counts are **panel counts for one day**; scaling to the US is step 05.

---

## 1. Result

| Brand | Affiliate landings | Clicks (incl. duplicates) | Panel duplicates | **Clicks** | Publishers | With `afsrc=1` |
|---|---:|---:|---:|---:|---:|---:|
| Walmart (whole site) | 11,931 | 3,338 | 104 | **3,234** | 221 | 2,775 (83%) |
| Walmart - mattress section | 255 | 64 | 0 | **64** | 20 | 60 (94%) |
| Saatva | 14 | 7 | 3 | **4** | 3 | **0** |
| Helix | 5 | 4 | 2 | **2** | 2 | 4 |
| Nectar | 8 | 3 | 0 | **3** | 2 | 3 |
| DreamCloud | 6 | 2 | 0 | **2** | 2 | 1 |

Walmart clicks come from 1,321 user IDs = **1,266 people** (after panel de-duplication, §4).
**Walmart (whole site)** = any product; it is the base for the Walmart hijacking analysis.
**Walmart - mattress section** = the Walmart clicks whose session included a mattress page (definition in
doc 07 §5): 64 clicks from 6 people. This is the like-for-like comparison with Saatva.
DTC volumes are tiny: comparisons between DTC brands are directional only (doc 03 §5.3).

## 2. Dictionary (one rule set for all brands)

Based on steps 01-02 (doc 03 §4, §8). A brand-site event is an **affiliate landing** if its URL carries:

| Source | Marker |
|---|---|
| Channel tag | `utm_medium=affiliate` / `aff` |
| Partnerize | `click_id`, `app_clickref`, `clickref` |
| Impact | `irgwc=1`, `irclickid`, `cidimp` |
| Walmart (Impact) | `veh=aff`, `wmlspartner(_creator)=imp_…`, `sourceid=imp_…`, `affiliates_ad_id(_creator)` |

**Not counted on their own** (kept as flags for step 06): `afsrc` (stand-down flag), `coupon` (also used
by email and other channels), paid-search markers (`gclid`, `gad_source`, `gbraid`, `wbraid`, `msclkid`,
`veh=sem`, `wmlspartner=wlpa`).

**Publisher** = Walmart/Impact partner ID (`wmlspartner=imp_…`), else Impact `ir_partnerid`, else
`utm_source`, else `(unknown)`.

**Robustness - independent markers agree:**

| Brand | Markers on the click | Clicks |
|---|---|---:|
| Saatva | UTM **and** Partnerize | 7 of 7 |
| Walmart | Impact **and** Walmart channel tag | 3,319 of 3,338 |
| Walmart | Walmart tag only / Impact only / UTM only | 16 / 2 / 1 |
| DreamCloud | UTM **and** Impact | 2 of 2 |
| Nectar | UTM **and** Impact / Impact only | 1 / 2 of 3 |
| Helix | Impact only (`irclickid` + `irgwc`) | 4 of 4 |

## 3. From landings to clicks

One click = **user × brand × publisher**; landings less than **30 minutes** apart are merged (redirects,
reloads, browsing back). A **different publisher opens a new click**, even within 30 minutes - merging
it would hide exactly the overwrite pattern step 06 must see.

| Window | Saatva | Helix | Nectar | DreamCloud | Walmart |
|---|---:|---:|---:|---:|---:|
| No merging (landings) | 14 | 5 | 8 | 6 | 11,931 |
| 10 min | 7 | 4 | 3 | 2 | 3,552 |
| **30 min (used)** | 7 | 4 | 3 | 2 | 3,338 |
| 60 min | 7 | 4 | 3 | 2 | 3,247 |

DTC counts do not move; Walmart moves ≈ ±6%. The window is a modelling choice, not a fact.

## 4. Panel duplicates: the same person under several USER_IDs

### 4.1 Evidence
In `click_examples`, the same network click ID (created once per click) appears under
2-3 USER_IDs **in the same second**. Comparing those IDs' **whole day** (same second + same host):

| | Pairs | Identical events (of the smaller ID's day) |
|---|---:|---|
| Saatva / Helix (shared click ID) | 7 / 3 | **100%** in every pair (e.g. 35 of 35; one partial copy: 14 of 31) |
| Walmart (shared `clickid`) | 1,457 | 971 pairs 0-20% · 38 pairs 20-50% · 15 pairs 50-90% · **433 pairs 90-100%** |

DTC pairs = one person logged several times. Walmart's `clickid` is shared by different people over hours
(a link-level ID, not a per-click ID) - but 433 Walmart pairs are still the same person.
So for Walmart a shared `clickid` is **not** used to merge IDs (it would merge 971 different people);
rule 2 below uses the whole-day fingerprint instead. Of the 433 pairs at 90-100%, it merges the 372
exact copies with ≥ 10 identical events; 33 near-copies (90-99%) and 28 pairs with < 10 identical events
are left separate, so the de-duplication is conservative (§4.3).

### 4.2 Rules (either one flags a click as `is_panel_duplicate`)

| Rule | Condition | Catches |
|---|---|---|
| 1 | same brand + same **per-click ID** (Partnerize / Impact) + same second, under another USER_ID | DTC duplicates, including **partial** copies |
| 2 | same brand + same **person** (identical-day fingerprint, `person_map`) + same second, under another USER_ID | Walmart duplicates (no per-click ID) |

`person_map`: per USER_ID, the number of distinct (second, host) events + the XOR of their hashes
(order-independent, one pass over `stg_events`). IDs with ≥ 10 events and an identical fingerprint share
a `person_id`. Exact copies only, so this is a **lower bound**. Under 10 events: too little evidence, kept separate.

Ranking uses `DENSE_RANK` on USER_ID, not `ROW_NUMBER`, so that a user's **own** several clicks in the
same second (publishers alternating within a second) are never flagged; only clicks under **another**
USER_ID are.

Nothing is deleted: duplicates are flagged and both counts are reported. Downstream steps use
`NOT is_panel_duplicate` and count people via `person_id`.

### 4.3 Is the decision sensitive to the threshold?

| Pairs judged "same person" (also ≥ 10 identical events) | at 50% | at 90% | at 100% |
|---|---:|---:|---:|
| Saatva | 7 | 7 | 7 |
| Helix | 3 | 3 | 3 |
| Walmart | 419 | 405 | 372 |

DTC: no. Walmart: 53 pairs fall between 20% and 90% and stay unresolved; rule 2 uses only exact
copies, so they are not merged.

### 4.4 Size in the whole panel

| | User IDs | People | Redundant IDs | Max IDs per person |
|---|---:|---:|---:|---:|
| Full data | 783,982 | **751,584** | **32,398 (4.1%)** | 8 |
| `--subset` (5% of IDs) | 38,866 | - | 85 (0.22%) | 3 |

**The subset under-states duplication ~20×, as expected:** a pair is visible in a user-level sample only
if **both** copies are sampled (p² = 1/400). 27,134 duplicate groups / 400 ≈ 68; the subset contains 84.
A user-level sample is right for rates, but not for phenomena that involve **pairs** of users; these are
measured on the full data.

**Implication for step 05:** the scaling base is people (≤ 751,584), not IDs (783,982).

## 5. Validation

| Check | Result |
|---|---|
| Synthetic fixture | Clicks equal the planted counts (DreamCloud 342, Helix 327, Nectar 310, Saatva 312, Walmart 376) |
| Synthetic + planted copies (2 full Saatva, 1 partial Saatva, 1 Walmart, 1 non-brand) | Each caught by the expected rule; panel count = 4 (partial copy excluded by design) |
| Synthetic, clean | 0 duplicates (no false positives) |
| Planted case: one user's own clicks in the same second | Not flagged (`DENSE_RANK` on USER_ID, §4.2) |
| `--dev` vs full | DTC rows identical (all DTC users are in `--dev`) |
| `--subset` vs full | Walmart 154 vs 3,338 clicks = 4.6% (≈ 5% sample) |
| `dedup_sanity` (no click loses every copy) | 0 rows on full data |

## 6. Findings carried to step 06 (fraud / attribution hijacking)

- **`afsrc=1` absent on every Saatva affiliate click** (0 of 7), present on Impact brands (Walmart 83%).
- **Paid-search marker on an affiliate click:** Saatva `brandxemail` (1 click) - the hijacking
  definition used in this analysis. Walmart: 39 clicks.
- **Publisher switches within 30 minutes:** 1,563 of 3,234 Walmart clicks (169 people) follow a different
  publisher's click within 30 minutes; e.g. a landing with `afsrc=1` followed 3 s later by another
  publisher's tag, entered from walmart.com itself. Not all are fraud (price-comparison users click
  several offers); quantified in doc 08 §4.
- **Publishers to profile:** `imp_6144707` (471 clicks from 54 users, ~9 per user; alternating publishers
  within one second), `imp_1390754` (511 clicks / 311 users, often entered from walmart.com itself),
  `imp_101044` (entered from Capital One shopping/offers pages), Saatva `trafficpoint12345` (also on
  DreamCloud as `trafficpoint-2`), DreamCloud `wickfire` (known paid-search affiliate).

## 7. Intermediate tables

| Table | Purpose | Logic |
|---|---|---|
| `affiliate_landings` | One row per brand-site event with an affiliate marker | Dictionary §2; markers as booleans; publisher; per-click ID |
| `person_map` | USER_ID to person_id | Whole-day fingerprint, ≥ 10 events (§4.2) |
| `affiliate_clicks` | One row per click | 30-min merge per user × brand × publisher; `is_panel_duplicate` (§4.2) |
| `shared_click_pairs` | Diagnostic: pairs of IDs sharing a click ID | Whole-day overlap per pair |

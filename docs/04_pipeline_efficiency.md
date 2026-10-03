# 04 · Pipeline Efficiency: Staging, Samples, Reproducibility

> Goals: efficient queries, development and validation on samples before the full data, and
> documented intermediate tables. This document describes the design, its rationale and the
> measured effect.

---

## 1. The cost of reading the Parquet files in every check

`raw_events` is a view over the Parquet files. Reading it directly in every SQL block means that the
14 profiling checks make **14 full scans of 12 GB / 48.4 M rows**. Measured on the full data with
direct reads, the first three checks alone take ≈17 minutes, and the fourth had not finished after
several more minutes:

| Check (direct reads, full data) | Time |
|---|---:|
| `overview` | 340 s |
| `completeness` | 44 s |
| `uniqueness` | 630 s |
| `dup_id_examples` | not completed after several minutes |

## 2. The staging step (`sql/00_stage.sql`)

Read the Parquet files **once per run mode**, precompute everything later steps need, store it as a
native DuckDB table. Every later step reads that table.

| Intermediate table | Purpose | Logic |
|---|---|---|
| `brand_users` | Users relevant to the brand analysis | Distinct hashed `USER_ID` whose `SUBDOMAIN` or `URL` contains a brand token (case-insensitive regex) |
| `stg_events` | One compact row per event for all later steps | Columns below |
| `bu_events` (step 01) | Journeys of brand users | `stg_events` rows of brand users + previous/next event per user (`LAG`/`LEAD`) |
| `brand_params` (step 02) | One row per (brand-site event, URL parameter) | Query string split into key / value |

**`stg_events` columns and the trade-off behind each**

| Column(s) | What | Why |
|---|---|---|
| `USER_ID`, `SESSION_ID`, `ID_HASH` | 64-bit hashes of the original IDs | ~4-8× smaller than 32+ character strings; faster joins and `GROUP BY`. Collision probability negligible at this scale (≈1e-8 users, ≈1e-7 sessions, ≈6e-5 events) |
| `host`, `url_host` | URL host, lower-case, `www.` stripped (fallback `SUBDOMAIN`) | Computed once instead of in every step (doc 02 decision) |
| `brand` | Main US shopping site of the 5 brands | Computed once |
| `search_page` | Search-result page type (Google / Bing / … / non-search Google page) | Tests the "no search pages" hypothesis without another scan |
| `url_hash`, `is_http` | Hash of the URL; http(s) flag | Enough for the duplicate and validity checks |
| `URL`, `_ID` | Original values - **only for brand users' events** | Only these rows need parameters and journey order; keeping URL for all 48 M rows would make staging as large as the input |
| `miss_*` | Missing / empty flags per original column | Completeness must be checked before hashing (`hash(NULL)` is not NULL) |

Other optimisations:
- **Distinct-first regex.** The seed-domain check matches 14 patterns against the *distinct* hosts
  (thousands) and joins back, instead of against every event (millions). Synthetic: from 7.1 s to 0.0 s.
- **Filter early.** The brand analysis runs on brand users only (≈5% of rows).
- **Resource caps.** `--memory` (default 4 GB) and `--threads` (default half the cores); DuckDB
  spills to `data/intermediate/tmp` instead of running out of memory.
- **Separate state per run mode.** Full / `--subset` / `--dev` / synthetic each have their own output
  folder and database, so they never overwrite each other and can be compared.

## 3. Correctness: regression test

Comparison on the synthetic fixture (direct-read pipeline vs. staged pipeline, steps 00-02):

| Check | Result |
|---|---|
| Output files compared | 24 |
| Identical numbers | 23 |
| Different | 1 - `search_engine_presence`: 8 more "Google, non-search" rows. These are the planted rows whose `SUBDOMAIN` was corrupted to `unknown.example`; the staged version classifies by the URL host, which is **more correct** |
| Two consecutive runs | Byte-identical (see §4) |
| Runtime, synthetic, steps 00-02 | from 7.9 s to 1.0 s |

## 4. Reproducibility

Examples are chosen with `MIN()` rather than `ANY_VALUE()` (arbitrary), and every top-N / sort has a
tie-breaker, so the same input always produces byte-identical outputs.

## 5. Sampling (subset-first)

See doc 03 §2: a random 5% user subset (`--subset`, representative, used for rates) and a stratified dev
sample (`--dev`, §5.1, validates DTC and Walmart-mattress logic exactly). The samples are used to
develop and validate the logic; the full run is checked against them.

**Limit of user-level samples (doc 05 §4.4).** A sample of user IDs is right for rates, but
under-states anything that involves **pairs** of IDs: a duplicate pair is visible only if both
copies are sampled (p² = 1/400 at 5%). Panel duplication measures 0.22% on `--subset` and 4.1% on
the full data. Pair-based checks are therefore only reported from the full run.

### 5.1 The dev sample design

`--dev` = (1) all DTC-brand users + (2) all Walmart mattress shoppers + (3) random 5% of everyone
else + (4) the panel copies of the random-5% users. Rare segments are kept in full; the copy stratum
makes duplicate pairs visible, which a user-ID sample sees only with p² = 1/400.

| Stratum | Why | Definition |
|---|---|---|
| DTC-brand users | A random 5% holds only 1-3 users per DTC brand (doc 03 §2) | **All** users who touched a DTC brand |
| Walmart **mattress** shoppers (steps 05b, 07) | 53 people on the full data; a random 5% would hold ~2-3 of them | **All** Walmart mattress shoppers, same definition as 05b (product / search / category / brand / sponsored page on walmart.com whose URL contains "mattress") |
| Random 5% | Exercises the general logic on ordinary users | Random 5% of everyone else |
| **Panel copies** of random-5% users (step 03 `person_map`) | a pair is drawn only if both IDs are (p² = 1/400) | Other IDs that share **≥ 3 identical (second, URL)** Walmart page views with a random-5% user |

Strata 1 and 2 need no copy step: a copy has the same DTC / mattress pages, so it is selected anyway.

- **Built-in checks:** DTC **and** Walmart-mattress counts on `--dev` must equal the full data exactly
  (both strata are complete).
- **Cost:** a single scan of the Parquet files (DTC and Walmart rows are collected in one pass);
  the copy search is a self-join on Walmart page views only.
- **Synthetic-fixture test** with planted rows: a mattress shopper and a copy of a random-5% user are
  kept; a user who shares only one page view with a random-5% user is not.
- Rates are still never read from `--dev`: it is built to exercise the logic, not to represent the panel.

**Measured on the real data (2026-10-02):**

| | Result |
|---|---|
| Strata | 118 DTC users · 45 Walmart mattress shoppers (not already DTC) · 152 copies of random-5% users · + random 5%: 39,174 user IDs in total |
| Runtime | sample selection 23.7 s; steps 00-07 end to end **61.5 s** |
| Exact checks vs the full run | 13 outputs compared (mattress comparison and page types; channel mix; cross-shopping; referring sites; publishers; scorecard; DTC clicks, conversions, signals, journeys): **0 differences** |
| Walmart duplicate logic | random 5% (`--subset`): 0 duplicate clicks, so rule 2 never exercised. `--dev`: **6** duplicate Walmart clicks flagged; 79 Walmart pairs sharing a `clickid`, 38 of them at 90-100% overlap (same bimodal shape as the full data) |
| Panel-wide duplicate rate on `--dev` | 0.31% (full: 4.1%). Expected: copies are searched on Walmart pages only, and most of the panel's duplicates are people who never visit Walmart. The sample is built to test the logic where the analysis runs, not to measure the rate |

## 6. Measured on the real data

### 6.1 Random 5% subset (2.44 M rows, 38,866 users)

| Run | Direct reads | Staged |
|---|---:|---:|
| Staging (one-time per run mode) | - | 33.6 s |
| Profiling, 14 checks | ≈ 166 s (each check re-reads the Parquet files) | **3.0 s** |
| Steps 00 + 01 + 02 end to end | - | **40.4 s** |

**Same results on real data.** All 14 profiling outputs are identical between direct reads and
staging (rows, users, sessions, 0 duplicate IDs, 340,628 logical-duplicate groups, 21.197% host
mismatch, gap and activity percentiles). Step 01: every count is identical; the only difference is
which rows tied at the top-40 cut-off (4 entries each, Walmart) are listed - arbitrary without
tie-breakers, deterministic with them (§4).

### 6.2 Anchored domain patterns, checked on samples first

All domain patterns are anchored on whole labels, `(^|\.)bing\.com$`, because a plain suffix match
would count `plumbing.com` as Bing and `killedbygoogle.com` as Google (on `--dev`, a suffix match
puts 3,010 events, mostly plumbing websites, into the "other Bing / DuckDuckGo / Yahoo page" category).
Samples run before the full data so that errors of this kind cost a 40-second run rather than a
full-data run.

### 6.3 Full data (48.4 M rows, 783,982 users)

| Check / step | Direct reads | Staged |
|---|---:|---:|
| `overview` | 340 s | 99 s |
| `completeness` | 44 s | 0.5 s |
| `uniqueness` | 630 s | 35 s |
| Remaining 11 profiling checks | not reached (4th check does not complete) | 285 s |
| Staging (one-time: read 12 GB once) | - | 499 s |
| **Steps 00 + 01 + 02, end to end** | **not completed**: ≈ 17 min for the first 3 of 14 checks | **978 s ≈ 16 min** |

Every later step (03-06) reads the staged tables and does not touch the Parquet files again.

**Where time still goes, and what would cut it further (not implemented; in priority order):**
- `build_stg_events` (477 s) is bounded by reading 12 GB once; acceptable.
- `dup_id_examples` (190 s) groups 48 M hashes only to list examples - redundant when `uniqueness`
  already shows 0 duplicates. Could run conditionally.
- `overview` (99 s) is dominated by `COUNT(DISTINCT)` on 48 M IDs; `approx_count_distinct` (HyperLogLog)
  would be near-instant at ~1% error, acceptable for profiling but not used, to keep exact counts.

### 6.4 Step 03 on the full data

| Block | Time | Note |
|---|---:|---|
| `build_affiliate_landings` | 3 s | reads the brand users' events (step 01), not the 48 M rows |
| `build_person_map` | 139 s (21 s on a re-run, files cached by the OS) | one pass over all 48 M staged rows; computed **once** and reused by `panel_duplicate_users` and steps 04-05 instead of being recomputed |
| everything else | < 10 s | |
| **Step 03 total** | 152 s first run · 31 s re-run | |

The whole-day fingerprint uses an order-independent XOR of event hashes, so it needs no sort and no
string concatenation of each user's day.

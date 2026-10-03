# 02 · Data Profiling Results

> Profiling (step 00) runs on the random 5% user subset (`--subset --steps 00`) and on the **full data**
> (`--steps 00`). Section 0 compares the two; the sections below report subset figures, and every
> finding holds on the full data (rates in §0).

---

## 0. Full data vs. 5% subset - is the subset representative?

| Metric | 5% subset | Full data | Subset share / rate |
|---|---:|---:|---|
| Rows | 2,441,193 | **48,395,506** | 5.04% of rows |
| Users | 38,866 | **783,982** | 4.96% of users |
| Sessions | 99,604 | **1,994,372** | 4.99% |
| Distinct subdomains | 180,045 | 1,463,602 | (long tail, not proportional) |
| Days covered | 1 | **1** (2026-05-01) | - |
| Missing / empty values | 0 | **0** | - |
| Duplicate `_ID`s | 0 | **0** | - |
| Logical duplicates (same user, time, URL) | 340,628 groups (13.95% of rows) | 6,733,672 groups (13.91%) | same rate |
| Host mismatch (`www.` prefix) | 21.20% | 21.60% | same rate |
| Median / max events per session | 7 / 40,099 | 7 / 40,099 | same |
| Gap between events p50 / p90 / p99 | 3 s / 122 s / 1,417 s | 3 s / 125 s / 1,427 s | same |
| Events per user p50 / p99 / max | 21 / 592 / 42,354 | 21 / 600 / 42,354 | same |
| Peak hours (UTC) | 15-17 (7.6-7.9%) | 15-17 (7.8-7.9%) | same |
| `.com` share | 64.26% | 64.23% | same |

**Conclusion:** the subset reproduces every rate of the full data within a fraction of a percentage
point, so it is a valid development sample, and all decisions below hold.

## 1. Overview (as measured on the subset)

| Metric | 5 % subset | Full data |
|---|---|---|
| Rows | 2,441,193 | 48,395,506 |
| Distinct `_ID` | 2,441,193 | 48,395,506 |
| Users | 38,866 | 783,982 |
| Sessions | 99,604 | 1,994,372 |
| Distinct subdomains | 180,045 | 1,463,602 |
| Time range | 2026-05-01 00:00 to 23:59 | **single day** |

### Critical: single-day dataset

All events fall on **2026-05-01**. This eliminates multi-day attribution windows
(7-day, 30-day) from the analysis. Attribution is therefore:

- **Same-session attribution** - did the user convert in the same session after
  an affiliate click?
- **Same-day attribution** - did the user convert on 2026-05-01 after an earlier
  affiliate click that day?

Brand comparisons remain valid (all brands share the same observation window),
but absolute conversion rates differ from what a 30-day window would yield.

---

## 2. Completeness 

Zero NULLs and zero empty strings across all six columns. No imputation needed.

---

## 3. Uniqueness

| Check | Result | Action |
|---|---|---|
| Duplicate `_ID` values | **0** | None - `_ID` is a reliable primary key |
| Logical duplicates (same user + time + URL, different `_ID`) | **340,628 groups** (~14 % of rows) | Deduplication required: collapse to one event per (user, URL, timestamp) |

The logical duplicates are consistent with redirect chains and page reloads producing
multiple tracking rows for a single user action. Without deduplication, click counts
would be inflated and conversion rates deflated.

---

## 4. URL validity & host mismatch

| Check | Count | % |
|---|---|---|
| Non-HTTP(S) URLs | 14,023 | 0.6 % |
| Unparseable host | 13,808 | 0.6 % |
| SUBDOMAIN ≠ URL host | 517,468 | **21.2 %** |

### Host mismatch is benign

All top-25 mismatches are **`domain.com`** (SUBDOMAIN) vs. **`www.domain.com`**
(URL host) - a `www` prefix discrepancy, not a data-quality issue.

**Fix:** normalize hosts by stripping `www.` when comparing. Use the URL-parsed
host as the authority; fall back to SUBDOMAIN when the URL is unparseable.

The ~0.6 % non-HTTP URLs (likely `chrome-extension://`, `about:blank`, etc.) are
browser-internal and are excluded from analysis.

---

## 5. Session consistency 

| Check | Result |
|---|---|
| Sessions with > 1 user | **0** |
| Sessions crossing UTC midnight | **0** (single-day data) |
| Median duration | 6 min |
| p99 duration | 271 min (~4.5 h) |
| Max duration | 1,439 min (~24 h) |
| Median events/session | 7 |
| Max events/session | **40,099**  |

Sessions are clean (one user each). The 40 K-event session is an outlier -
likely a bot or automated tool. Sessions can be used as the journey unit.

### Intra-session gaps

| Percentile | Gap |
|---|---|
| p50 | 3 s |
| p90 | 122 s (~2 min) |
| p99 | 1,417 s (~24 min) |
| max | 63,651 s (~17.7 h) |

Most consecutive events are seconds apart. The long-tail gaps (> 24 min at p99)
suggest some sessions contain idle periods, but the session boundaries are still
usable - no need to re-sessionize.

---

## 6. User activity distribution

| Stat | Events per user |
|---|---|
| Median | 21 |
| Mean | 63 |
| p90 | 142 |
| p99 | 592 |
| Max | **42,354** |

Heavy-tailed distribution. The top-1 % of users produce > 590 events each.
The max (42 K events from a single user in one day) is almost certainly automated.

**Action:** flag users with > p99 events for exclusion from affiliate metrics
(they inflate click counts but are unlikely to represent real purchase intent).

---

## 7. US-panel validation

### Hour-of-day profile (UTC)

Peak activity at **15:00-17:00 UTC** (10 AM - 12 PM US Eastern), trough at
**08:00-10:00 UTC** (3-5 AM Eastern). This matches a US-centric panel.

| UTC hour | % of events | US Eastern |
|---|---|---|
| 08-10 | 2.0-2.1 % | 3-5 AM (trough)  |
| 12-13 | 4.9-6.6 % | 7-8 AM (ramp-up) |
| 15-17 | 7.6-7.9 % | 10 AM-12 PM (peak)  |
| 00-02 | 3.4-3.5 % | 7-9 PM (evening)  |

### TLD distribution

| TLD | Share |
|---|---|
| `.com` | 64.3 % |
| `.net` / `.org` / `.edu` / `.gov` | 14.4 % |
| `.ru` | 1.3 % |
| `.uk` / `.ca` | 0.8 % |

Overwhelmingly US-oriented. The ~1.3 % `.ru` and scattered international TLDs are
consistent with a US panel whose users occasionally visit foreign sites.

**Conclusion:** the panel is US-based. No country filter needed, but non-US brand
domains (e.g. `walmart.ca`, `walmart.com.mx`) are excluded from brand metrics.

---

## 8. Brand coverage in the subset

Counts below are from the **random 5% user subset** (`--subset`, 99,604 sessions), not the full data.

| Brand | Events (subset) | Users (subset) | Subdomains |
|---|---|---|---|
| **Walmart** | 7,436 (6,358 on walmart.com) | 687 on walmart.com | 66 (walmart.com, seller., identity., …) |
| **Saatva** | 6 | ~2 | blog-staging.saatva.com, saatva.com, d.emails.saatva.com |
| **Nectar** | 1 | 1 | nectarsleep.com |
| **DreamCloud** | 1 | 1 | dreamcloudsleep.com |
| **Helix** | 0 | 0 | - |

### Implications

- **Walmart dominates** because it is a mass-market site; the DTC mattress brands
  are niche and appear rarely in a general browsing panel.
- The 5 % subset is **too small for DTC brand analysis**; brand metrics use the full
  dataset. Even there the DTC brands are small - main-site events: Saatva 82, Nectar 182,
  DreamCloud 90, Helix 65 (doc 03 §4.1) - which is itself a finding (these brands have low organic +
  affiliate traffic relative to Walmart).
- **Walmart subdomains to filter:** `walmart.ca`, `walmart.com.mx`, `walmart.com.gt`,
  `careers.walmart.com`, `corporate.walmart.com` and other non-shopping subdomains
  are excluded from conversion analysis.

---

## 9. Notable domains in the dataset

| Domain | Events | Users | Note |
|---|---|---|---|
| simplycodes.com | 13,293 | 28 | Coupon extension - very high events/user ratio, likely automated |
| capitaloneshopping.com | 2,260 | 320 | Shopping/cashback extension |
| paypal.com | 8,634 | 1,030 | Payment - potential conversion signal |
| deductgreedyheadroom.com | 2,168 | 11 | Suspicious domain name, low users - possible adware/tracker |

These are relevant for affiliate identification (coupon/cashback extensions are
a gray-zone publisher type) and fraud detection.

---

## 10. Decisions for the next steps

| Decision | Rationale |
|---|---|
| Use the **full dataset** for all brand analysis | DTC brands invisible in 5 % subset |
| Use **same-session** and **same-day** attribution only | Single-day data rules out multi-day windows |
| Normalize hosts by **stripping `www.`** | Resolves the 21 % mismatch |
| Deduplicate on **(USER_ID, URL, CREATED_TIME)** | 14 % logical duplicates |
| Flag users with **> 600 events/day** as potential bots | p99 = 592 events |
| Exclude **non-US brand domains** (`.ca`, `.mx`, `.co.uk`) | Panel is US-based |
| Exclude **non-shopping Walmart subdomains** | careers, corporate, etc. are not conversions |


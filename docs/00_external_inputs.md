# 00 · External Inputs & Background

Facts gathered from public sources **before** the analysis. They shape *where to look* in the
data (which tracking domains and parameters to expect); they are **not** used as results.


## Affiliate networks per brand

| Brand | Network(s) | Expected tracking footprint in clickstream | Source |
|---|---|---|---|
| **Saatva** | **Partnerize** (since Feb 2018), managed by agency JEBCommerce | Redirect `prf.hn/click/camref:<id>` (campaign ref in the path); landing URL carries `?clickref=<id>` | Network: [JEBCommerce](https://jebcommerce.com/now-managing-the-saatva-affiliate-program/), [Partnerize case study](https://go.partnerize.com/case-study-saatva). Tracking format: [Partnerize tracking-link guide](https://docs.partnerize.com/transferwise/Tracking_instructions_for_the_TransferWise_affiliate_program.pdf) (`prf.hn`, `camref`), [Partnerize S2S help article](https://help.phgsupport.com/hc/en-us/articles/360020395238-Tracking-Partnerize-Server-to-Server-S2S-Integration) (`clickref` on landing) |
| Saatva (secondary) | **Sovrn//Commerce (VigLink): verified** - merchant page lists saatva.com, saatvadreams.com, saatvamattress.com as open. Skimlinks: cited page renders no Saatva content, so **unverified**. Awin: no source, so **unverified** | `redirect.viglink.com`, `go.skimresources.com`, `awin1.com` (domains from general knowledge, unverified). Also check the extra brand domains `saatvadreams.com`, `saatvamattress.com` in the data | [VigLink merchant page](https://www.viglink.com/merchants/4994/saatva-inc-affiliate-program) |
| **Nectar** | Impact | Landing carries `irclickid` (+ `irgwc`). Redirect domain **unverified**: `*.sjv.io` / `*.pxf.io` / `*.7eer.net` are common Impact domains from general knowledge; Impact also uses per-brand domains (e.g. `imp.i317572.net` in a real example), so the domain list must come from the data | Network: [Nectar affiliates page](https://www.nectarsleep.com/l/affiliates). `irclickid` / `irgwc` in a real Impact landing URL: [Brave issue #33952](https://github.com/brave/brave-browser/issues/33952) |
| **Helix** | Impact (Helix has a brand page on Impact's marketplace; the page itself blocks automated reading, so content not checked) | same as Nectar | [Impact brand page](https://app.impact.com/campaign-campaign-info-v2/Helix-Sleep.brand) |
| **DreamCloud** | Same parent as Nectar (Resident Home, acquired by Ashley, announced March 2024), so network **unverified**, to confirm in data | to confirm | [PR Newswire: Ashley and Resident announce acquisition](https://www.prnewswire.com/news-releases/ashley-and-resident-announce-acquisition-302080558.html) |
| **Walmart** | Impact (since June 2019; earlier affiliates on Rakuten LinkShare); 72-hour cookie | Impact parameters expected. `goto.walmart.com`, `veh=aff`, `sourceid=imp_` are **unverified** (general knowledge) | [Geniuslink](https://geniuslink.com/blog/walmart-affiliate-program/) |

### Implications for the analysis
- **Saatva is a Partnerize client.** The analysis should speak the network's language (publisher,
  EPC, revenue-producing partners) and avoid claims the clickstream cannot support.
- Partnerize's public case study reports Saatva's program growth in **revenue (+62% YoY)**,
  **revenue-producing partners (+48%)** and **EPC (+27%)**. These are useful framing KPIs: the
  driver tree in doc 01 (publishers × clicks per publisher × conversion) maps directly onto them.
- **Nectar and DreamCloud share a parent company.** Expect overlapping publishers and similar
  program structure; treat them as a natural pair when comparing.
- **Different attribution windows by brand** (Walmart 72 h vs. typical 30-day DTC windows) mean a
  single fixed window is a modeling choice, not the brands' actual payout rule.
- Networks differ by brand, so a parameter dictionary built **per brand from the data** is required;
  a single hard-coded list would undercount the brands on networks we did not anticipate.

## Scaling input

| Input | Value | Source | Use |
|---|---|---|---|
| US internet users | ≈ 322 M (January 2025, 93.1% of 346 M) | [DataReportal, Digital 2025: United States of America](https://datareportal.com/reports/digital-2025-united-states-of-america) | Denominator for the US scale factor (doc 07) |

Caveat: the panel population is closer to *desktop browser users with an extension installed* than
to all US internet users. The absolute US estimates inherit this uncertainty; brand comparisons and ratios are much less affected, since the bias applies to all brands alike.

"""
Small synthetic clickstream (same schema as the real data) to test the pipeline.

Planted cases: affiliate journeys (publisher, redirect, landing), reloads, conversions,
hijacked clicks (search, then a redirect within 1 s), duplicate _IDs, host mismatches and a
non-US domain.
"""
import random
import uuid
from datetime import datetime, timedelta
from pathlib import Path

import pandas as pd

random.seed(42)
OUT = Path(__file__).resolve().parents[1] / "data" / "synthetic"
OUT.mkdir(parents=True, exist_ok=True)

BRANDS = {
    "saatva": ("www.saatva.com", "https://www.saatva.com", "prf.hn", "clickref"),
    "nectar": ("www.nectarsleep.com", "https://www.nectarsleep.com", "nectarsleep.sjv.io", "irclickid"),
    "helix": ("helixsleep.com", "https://helixsleep.com", "helixsleep.pxf.io", "irclickid"),
    "dreamcloud": ("www.dreamcloudsleep.com", "https://www.dreamcloudsleep.com", "dreamcloud.sjv.io", "irclickid"),
    "walmart": ("www.walmart.com", "https://www.walmart.com", "goto.walmart.com", "affiliates_ad_id"),
}
PUBLISHERS = ["www.sleepfoundation.org", "www.mattressclarity.com", "www.nytimes.com",
              "www.retailmenot.com", "www.rakuten.com", "www.reddit.com"]
NOISE = ["www.google.com", "mail.google.com", "www.youtube.com", "www.facebook.com",
         "www.amazon.com", "en.wikipedia.org", "www.cnn.com"]

rows = []


def add(t, user, session, url, subdomain=None):
    host = subdomain or url.split("/")[2]
    rows.append({"CREATED_TIME": t, "USER_ID": user, "SUBDOMAIN": host, "URL": url,
                 "SESSION_ID": session, "_ID": uuid.uuid4().hex})


start = datetime(2025, 1, 1)
for u in range(3000):
    user = f"u{u:05d}"
    for d in random.sample(range(30), k=random.randint(1, 6)):
        session = uuid.uuid4().hex
        # US-like activity: 13:00-04:00 UTC
        t = start + timedelta(days=d, hours=random.choice(list(range(13, 24)) + [0, 1, 2, 3]),
                              minutes=random.randint(0, 59))
        for _ in range(random.randint(2, 8)):  # background browsing
            add(t, user, session, f"https://{random.choice(NOISE)}/p{random.randint(1, 500)}")
            t += timedelta(seconds=random.randint(5, 300))

        if random.random() < 0.25:  # mattress journey
            brand = random.choice(list(BRANDS))
            sub, base, net, param = BRANDS[brand]
            r = random.random()
            if r < 0.5:  # genuine affiliate click
                pub = random.choice(PUBLISHERS)
                add(t, user, session, f"https://{pub}/best-mattress-2025")
                t += timedelta(seconds=random.randint(20, 240))
                add(t, user, session, f"https://{net}/click/camref:{pub[:6]}")
                t += timedelta(milliseconds=random.randint(300, 1500))
                land = f"{base}/mattresses?{param}={uuid.uuid4().hex[:10]}&utm_medium=affiliate"
                add(t, user, session, land)
                if random.random() < 0.3:  # reload -> duplicate landing row
                    add(t + timedelta(seconds=2), user, session, land)
            elif r < 0.65:  # hijacked: brand search -> redirect within <1s, no publisher page
                add(t, user, session, f"https://www.google.com/search?q={brand}+mattress")
                t += timedelta(milliseconds=random.randint(100, 900))
                add(t, user, session, f"https://{net}/click/camref:xtnsn1")
                t += timedelta(milliseconds=400)
                add(t, user, session, f"{base}/?{param}={uuid.uuid4().hex[:10]}&gclid=abc")
            else:  # organic
                add(t, user, session, f"https://www.google.com/search?q={brand}")
                t += timedelta(seconds=5)
                add(t, user, session, f"{base}/")
            t += timedelta(seconds=random.randint(30, 600))
            if random.random() < 0.12:  # conversion
                add(t, user, session, f"{base}/checkout")
                add(t + timedelta(seconds=90), user, session, f"{base}/checkout/order-confirmation")

df = pd.DataFrame(rows)
# planted data-quality issues
df = pd.concat([df, df.sample(20, random_state=1)])                            # duplicate _IDs
df.loc[df.sample(15, random_state=2).index, "SUBDOMAIN"] = "unknown.example"  # host mismatch
add(datetime(2025, 1, 5, 10), "u99999", "sx", "https://www.nectarsleep.co.uk/")  # non-US
df = pd.concat([df, pd.DataFrame(rows[-1:])])

for i, part in enumerate(range(0, len(df), len(df) // 3 + 1)):
    df.iloc[part:part + len(df) // 3 + 1].to_parquet(OUT / f"part-{i:03d}.parquet", index=False)
print(f"wrote {len(df):,} rows to {OUT}")

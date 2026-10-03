"""
Run the SQL files in sql/ with DuckDB.

Each file is split into "-- name:" blocks. CREATE blocks build tables; SELECT blocks are saved to
outputs/<step><suffix>/<block>.csv. Each run mode has its own outputs and DuckDB file.

    python src/run_pipeline.py                                    # full data in data/raw/
    python src/run_pipeline.py --subset                           # random 5% of users
    python src/run_pipeline.py --dev                              # dev sample (logic checks)
    python src/run_pipeline.py --data data/synthetic --steps 00   # synthetic test data

00_stage reads the Parquet files once; later steps read the staged tables.

--subset: random 5% of users, used to check that rates match the full data.
--dev:    every DTC user, every Walmart mattress shopper, a random 5% of the rest, and the
          duplicate IDs of those 5% (so person_map has pairs to work on). For logic checks only:
          DTC and mattress results must equal the full run.
Samples are always by user, never by row, so sessions stay whole.

--memory (default 4GB) and --threads (default half the cores) cap DuckDB, which spills to disk.
"""
import argparse
import os
import re
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
OUT_DIR = ROOT / "outputs"
BLOCK_RE = re.compile(r"^--\s*name:\s*(\w+)\s*$", re.MULTILINE)
DTC_TOKENS = "saatva|nectarsleep|helixsleep|dreamcloudsleep"


def split_blocks(sql_text: str) -> list[tuple[str, str]]:
    """Return [(name, statement)] for every `-- name:` block in a file."""
    parts = BLOCK_RE.split(sql_text)
    return [(parts[i], parts[i + 1].strip().rstrip(";")) for i in range(1, len(parts), 2)]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data/raw", help="folder with Parquet files")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--subset", action="store_true", help="random ~5%% of users (hash-based)")
    mode.add_argument("--dev", action="store_true", help="all DTC users + all Walmart mattress shoppers + random 5%% + panel copies of the 5%%")
    ap.add_argument("--steps", nargs="*", help="SQL file prefixes to run, e.g. 00 01")
    ap.add_argument("--memory", default="4GB", help="DuckDB memory limit (default 4GB)")
    ap.add_argument("--threads", type=int, default=max(1, (os.cpu_count() or 2) // 2),
                    help="DuckDB threads (default: half the cores)")
    args = ap.parse_args()

    suffix = "_subset" if args.subset else "_dev" if args.dev else ""
    if Path(args.data).as_posix().rstrip("/") != "data/raw":
        suffix = "_" + Path(args.data).name + suffix
    inter = ROOT / "data" / "intermediate"
    (inter / "tmp").mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(inter / f"analysis{suffix}.duckdb"))
    con.execute(f"SET memory_limit = '{args.memory}'")
    con.execute(f"SET threads = {args.threads}")
    con.execute(f"SET temp_directory = '{(inter / 'tmp').as_posix()}'")   # spill here, not RAM
    con.execute("SET preserve_insertion_order = false")                  # lowers memory use
    print(f"mode={suffix or 'full'}  memory_limit={args.memory}  threads={args.threads}")

    glob = (ROOT / args.data / "**" / "*.parquet").as_posix()
    src = f"read_parquet('{glob}', hive_partitioning = false)"
    random_5pct = "hash(USER_ID) % 20 = 0"

    # staging first; --steps matches file prefixes (00 = stage + profile, 00_profile = checks only)
    files = sorted(SQL_DIR.glob("*.sql"), key=lambda f: (f.name[:2], "stage" not in f.stem, f.name))
    if args.steps:
        files = [f for f in files if any(f.stem.startswith(s) for s in args.steps)]
    staging = any("stage" in f.stem for f in files)
    if not staging:
        staged = con.execute("SELECT COUNT(*) FROM information_schema.tables "
                             "WHERE table_name = 'stg_events'").fetchone()[0]
        if not staged:
            raise SystemExit("stg_events not found for this run mode: include step 00 (staging), "
                             "e.g. --steps 00_stage 01")
    # the sample is applied at staging; later steps just read the staged tables
    if not staging and (args.dev or args.subset):
        print("sample: re-using the staged tables of this run mode (no new scan)")

    if staging and args.dev:
        t0 = time.time()
        # one pass over the Parquet files: DTC users and Walmart page views
        con.execute(f"""
            CREATE OR REPLACE TABLE dev_scan AS
            SELECT USER_ID, CREATED_TIME, URL,
                   REGEXP_MATCHES(LOWER(SUBDOMAIN), '{DTC_TOKENS}')
                OR REGEXP_MATCHES(LOWER(URL),       '{DTC_TOKENS}')                  AS is_dtc,
                   REGEXP_MATCHES(URL, '(?i)^https?://(www\\.)?walmart\\.com([/?#:]|$)') AS is_walmart
            FROM {src}
            WHERE REGEXP_MATCHES(LOWER(SUBDOMAIN), '{DTC_TOKENS}|walmart')
               OR REGEXP_MATCHES(LOWER(URL),       '{DTC_TOKENS}|walmart')
        """)
        con.execute(f"""
            CREATE OR REPLACE TABLE dev_users AS
            WITH wm AS (SELECT USER_ID, CREATED_TIME, URL FROM dev_scan WHERE is_walmart),
            dtc AS (SELECT DISTINCT USER_ID FROM dev_scan WHERE is_dtc),
            mattress AS (   -- same definition as 05b
                SELECT DISTINCT USER_ID FROM wm
                WHERE LOWER(URL) LIKE '%mattress%'
                  AND REGEXP_EXTRACT(LOWER(URL), '^[a-z]+://[^/?#]+/([a-z]+)', 1)
                      IN ('ip', 'search', 'browse', 'cp', 'brand', 'sp')
            ),
            copies AS (     -- IDs with >= 3 identical Walmart page views as a random-5% user
                SELECT o.USER_ID
                FROM wm r
                JOIN wm o ON o.CREATED_TIME = r.CREATED_TIME AND o.URL = r.URL AND o.USER_ID <> r.USER_ID
                WHERE hash(r.USER_ID) % 20 = 0 AND hash(o.USER_ID) % 20 <> 0
                GROUP BY o.USER_ID, r.USER_ID
                HAVING COUNT(DISTINCT (r.CREATED_TIME, r.URL)) >= 3
            )
            SELECT USER_ID, MIN(stratum) AS stratum
            FROM (SELECT USER_ID, '1_dtc' AS stratum FROM dtc
                  UNION ALL SELECT USER_ID, '2_walmart_mattress' FROM mattress
                  UNION ALL SELECT DISTINCT USER_ID, '4_copy_of_random_user' FROM copies)
            GROUP BY USER_ID
        """)
        for stratum, n in con.execute("SELECT stratum, COUNT(*) FROM dev_users GROUP BY 1 ORDER BY 1").fetchall():
            print(f"dev sample: {stratum:<24} {n:>6} users kept in full")
        print(f"dev sample: 3_random_5pct             + hash(USER_ID) % 20 = 0   ({time.time() - t0:.1f}s)")
        user_filter = f"WHERE {random_5pct} OR USER_ID IN (SELECT USER_ID FROM dev_users)"
    elif args.subset:
        user_filter = f"WHERE {random_5pct}"
    else:
        user_filter = ""

    if staging:
        con.execute(f"CREATE OR REPLACE VIEW raw_events AS SELECT * FROM {src} {user_filter}")

    run_t0 = time.time()

    for f in files:
        out = OUT_DIR / (("profile" if f.stem.startswith("00") else f.stem) + suffix)
        out.mkdir(parents=True, exist_ok=True)
        for name, stmt in split_blocks(f.read_text(encoding="utf-8")):
            t0 = time.time()
            body = re.sub(r"--.*", "", stmt).strip()   # skip comments
            if re.match(r"(CREATE|INSERT|DROP)\b", body, re.IGNORECASE):
                con.execute(stmt)
                print(f"[{f.stem}] {name:<28} built   ({time.time() - t0:.1f}s)")
            else:
                df = con.execute(stmt).df()
                df.to_csv(out / f"{name}.csv", index=False)
                print(f"[{f.stem}] {name:<28} {len(df):>6} rows ({time.time() - t0:.1f}s)")
    print(f"total: {time.time() - run_t0:.1f}s")


if __name__ == "__main__":
    main()

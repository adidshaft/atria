#!/usr/bin/env bash
set -euo pipefail

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

source_csv="$tmpdir/polar-export.csv"
prepared_csv="$tmpdir/reference-rr.csv"
derived_csv="$tmpdir/derived.csv"
derived_out="$tmpdir/derived-out.csv"
bad_time_csv="$tmpdir/bad-time.csv"

cat > "$source_csv" <<'CSV'
timestamp,R-R Interval [ms]
0,1000
1,1010
2,990
3,1005
4,995
5,1000
6,1000
CSV

python3 prepare_reference_rr.py "$source_csv" "$prepared_csv" --window-s 3 --window-end-s 5 > "$tmpdir/prepare.log"

grep -q 'rows=4 duration=3.0s rr_column=R-R Interval \[ms\] time_column=timestamp timeline=timestamp_column' "$tmpdir/prepare.log"
grep -q "Wrote $prepared_csv" "$tmpdir/prepare.log"

cat > "$tmpdir/expected.csv" <<'CSV'
elapsed_ms,rr_ms
0,990
1000,1005
2000,995
3000,1000
CSV

diff -u "$tmpdir/expected.csv" "$prepared_csv"

cat > "$derived_csv" <<'CSV'
IBI [ms]
800
810
790
805
CSV

python3 prepare_reference_rr.py "$derived_csv" "$derived_out" > "$tmpdir/derived.log"
grep -q 'rows=4 duration=2.4s rr_column=IBI \[ms\] time_column= timeline=derived_from_rr' "$tmpdir/derived.log"

cat > "$tmpdir/derived-expected.csv" <<'CSV'
elapsed_ms,rr_ms
0,800
800,810
1610,790
2400,805
CSV

diff -u "$tmpdir/derived-expected.csv" "$derived_out"

cat > "$bad_time_csv" <<'CSV'
elapsed_ms,rr_ms
0,1000
0,1000
CSV

if python3 prepare_reference_rr.py "$bad_time_csv" "$tmpdir/bad-out.csv" > "$tmpdir/bad.log" 2>&1; then
  printf 'FAIL: non-monotonic reference timestamps were accepted\n' >&2
  exit 1
fi
grep -q 'Reference timestamps must be strictly increasing' "$tmpdir/bad.log"

printf 'PASS: reference RR preparation normalizes common exports\n'

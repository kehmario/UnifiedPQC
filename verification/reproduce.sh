#!/usr/bin/env bash
# =============================================================================
#  reproduce.sh  --  independently reproduce the NIST ACVP validation chain
#  for the unified ML-KEM/ML-DSA accelerator's shared NTT engine.
#
#  It does NOT trust any pre-computed file. It:
#    1. Pulls the NIST ACVP vectors straight from usnistgov/ACVP-Server
#    2. SHA-256 hashes them (so you can compare against the report)
#    3. Clones the independent FIPS 203/204 reference (py-acvp-pqc)
#    4. Runs the reference against the vectors (authenticity screening)
#    5. Extracts NTT KATs from real ACVP KeyGen cases (public key == ACVP)
#    6. Simulates the hardware NTT on those KATs and byte-compares
#
#  Requirements: bash, git, curl, python3 (+pip), and Icarus Verilog (iverilog/vvp).
#  The hardware files (pqc_ntt_mont_synth.v, twiddle_init.vh, tb_batch.v) must sit
#  next to this script -- they ship in the same folder.
#
#  Usage:   ./reproduce.sh            (uses ./repro_work as the scratch dir)
#           WORK=/tmp/foo ./reproduce.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/repro_work}"
NIST_BASE="https://raw.githubusercontent.com/usnistgov/ACVP-Server/master/gen-val/json-files"
PYACVP="https://github.com/mjosaarinen/py-acvp-pqc.git"

# vector folders we use (KeyGen provides the seeds we anchor NTT KATs to;
# the others are pulled so screening covers Encaps/Decaps/Sign/Verify too)
FOLDERS=(
  ML-KEM-keyGen-FIPS203  ML-KEM-encapDecap-FIPS203
  ML-DSA-keyGen-FIPS204  ML-DSA-sigGen-FIPS204  ML-DSA-sigVer-FIPS204
)

say(){ printf '\n=== %s ===\n' "$*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "MISSING TOOL: $1"; exit 1; }; }

need git; need curl; need python3
HAVE_IVERILOG=1; command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1 || HAVE_IVERILOG=0

mkdir -p "$WORK"; cd "$WORK"

# ----------------------------------------------------------------------------
say "1. Pull NIST ACVP vectors from usnistgov/ACVP-Server (fresh)"
mkdir -p nist
for f in "${FOLDERS[@]}"; do
  echo "  fetching $f/internalProjection.json"
  curl -fsSL "$NIST_BASE/$f/internalProjection.json" -o "nist/$f.json"
done

say "2. SHA-256 of the downloaded NIST files (compare to the report)"
if command -v sha256sum >/dev/null 2>&1; then sha256sum nist/*.json
else shasum -a 256 nist/*.json; fi

# ----------------------------------------------------------------------------
say "3. Clone the independent FIPS 203/204 reference (py-acvp-pqc)"
if [ ! -d py-acvp-pqc ]; then git clone --depth 1 "$PYACVP"; fi
echo "  py-acvp-pqc commit: $(git -C py-acvp-pqc rev-parse --short HEAD)"
python3 -c "import Crypto" 2>/dev/null || pip install --quiet --break-system-packages pycryptodome 2>/dev/null || pip install --quiet pycryptodome

# Point the reference at OUR freshly-pulled vectors (overwrite its mirror copy),
# so screening runs against the files we just hashed -- not a vendored copy.
for f in "${FOLDERS[@]}"; do
  if [ -d "py-acvp-pqc/json-copy/$f" ]; then
    cp "nist/$f.json" "py-acvp-pqc/json-copy/$f/internalProjection.json"
  fi
done

say "4. Screen vectors: run the reference (verbatim) -- expect 0 FAIL"
( cd py-acvp-pqc && python3 fips203.py 2>&1 | grep -E "PASS|FAIL" )
( cd py-acvp-pqc && python3 fips204.py 2>&1 | grep -E "PASS|FAIL" )

# ----------------------------------------------------------------------------
say "5. Extract NTT KATs from real ACVP KeyGen cases (public key == ACVP)"
python3 - "$WORK" << 'PY'
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1],'py-acvp-pqc'))
os.chdir(os.path.join(sys.argv[1],'py-acvp-pqc'))
import fips203, fips204

def extract(scheme, path, seedkeys, pkkey, q, width, run):
    d=json.load(open(path)); g=d['testGroups'][0]
    inst=(fips203.ML_KEM if scheme=='kem' else fips204.ML_DSA)(g['parameterSet'])
    pairs=[]; ver=0
    for t in g['tests'][:8]:
        caps=[]; orig=inst.ntt
        inst.ntt=lambda x,orig=orig,caps=caps:(lambda r:(caps.append((list(x),list(r))) if len(caps)<1 else None) or r)(orig(x))
        pk = run(inst, t); inst.ntt=orig
        exp=t.get(pkkey)
        if exp and pk.hex().upper()==exp.upper(): ver+=1
        pairs.append(caps[0])
    out=os.path.join(sys.argv[1], f'{scheme}_batch.mem')
    with open(out,'w') as f:
        f.write(f"{len(pairs)}\n")
        for fin,fout in pairs:
            for c in fin:  f.write(f"{c%q:0{width}x}\n")
            for c in fout: f.write(f"{c%q:0{width}x}\n")
    print(f"  {scheme.upper()}: {len(pairs)} KATs extracted, {ver}/{len(pairs)} KeyGen public keys == ACVP expected")

W=sys.argv[1]
extract('kem', f'{W}/nist/ML-KEM-keyGen-FIPS203.json', ('d','z'), 'ek', 3329, 4,
        lambda inst,t: inst.keygen_internal(bytes.fromhex(t['d']), bytes.fromhex(t['z']))[0])
extract('dsa', f'{W}/nist/ML-DSA-keyGen-FIPS204.json', ('seed',), 'pk', 8380417, 6,
        lambda inst,t: inst.keygen_internal(bytes.fromhex(t['seed']))[0])
PY

# ----------------------------------------------------------------------------
say "6. Simulate the hardware NTT on the ACVP KATs and byte-compare"
if [ "$HAVE_IVERILOG" = "0" ]; then
  echo "  iverilog/vvp not found -- skipping the hardware step."
  echo "  Install Icarus Verilog and re-run to reproduce the 8/8 byte-exact result."
else
  cp "$HERE/pqc_ntt_mont_synth.v" "$HERE/twiddle_init.vh" "$HERE/tb_batch.v" "$WORK"/
  ( cd "$WORK" && iverilog -g2012 -o batch pqc_ntt_mont_synth.v tb_batch.v 2>&1 | grep -v -i warning || true )
  ( cd "$WORK" && vvp batch +MS=0 +MEM=kem_batch.mem | grep -E "ACVP|mismatch" )
  ( cd "$WORK" && vvp batch +MS=1 +MEM=dsa_batch.mem | grep -E "ACVP|mismatch" )
fi

say "DONE"
echo "If step 4 shows 0 FAIL, step 5 shows public keys == ACVP, and step 6 shows"
echo "8/8 byte-exact, you have independently reproduced the report's chain."
echo "Compare the hashes in step 2 against NIST_ACVP_RAW_REPORT.txt section [1]."

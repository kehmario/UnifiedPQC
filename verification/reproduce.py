#!/usr/bin/env python3
# =============================================================================
#  reproduce.py  --  independently reproduce the NIST ACVP validation chain for
#  the unified ML-KEM/ML-DSA accelerator's shared NTT engine.  NATIVE WINDOWS /
#  cross-platform: no bash, no WSL.  Run it from PowerShell or cmd:
#
#      python reproduce.py
#
#  It does NOT trust any pre-computed file.  It:
#    1. Downloads the NIST ACVP vectors from usnistgov/ACVP-Server (stdlib urllib)
#    2. SHA-256 hashes them (compare against NIST_ACVP_RAW_REPORT.txt)
#    3. Clones the independent FIPS 203/204 reference (py-acvp-pqc) at a pinned commit
#    4. Runs the reference against the vectors (authenticity screening)
#    5. Extracts NTT KATs from real ACVP KeyGen cases (public key == ACVP)
#    6. Simulates the hardware NTT (iverilog/vvp) on those KATs and byte-compares
#
#  Requirements (all must be on PATH):
#    - Python 3.8+          (you have it)
#    - git                  (Git for Windows: https://git-scm.com/download/win)
#    - Icarus Verilog       (https://bleyer.org/icarus  -> iverilog.exe, vvp.exe)
#  pycryptodome is installed automatically into the current Python if missing.
#
#  The hardware files (pqc_ntt_mont_synth.v, twiddle_init.vh, tb_batch.v) must sit
#  in the same folder as this script -- they ship alongside it.
#
#  If iverilog/vvp are not found, steps 1-5 still run and the script tells you how
#  to finish step 6.  Nothing here is Windows-only; it also runs on macOS/Linux.
# =============================================================================
import sys, os, json, hashlib, subprocess, shutil, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORK = Path(os.environ.get("WORK", HERE / "repro_work")).resolve()
NIST_BASE = "https://raw.githubusercontent.com/usnistgov/ACVP-Server/master/gen-val/json-files"
PYACVP_URL = "https://github.com/mjosaarinen/py-acvp-pqc.git"
PYACVP_COMMIT = "1c85995"     # pinned; the snapshot this validation was built against

FOLDERS = [
    "ML-KEM-keyGen-FIPS203", "ML-KEM-encapDecap-FIPS203",
    "ML-DSA-keyGen-FIPS204", "ML-DSA-sigGen-FIPS204", "ML-DSA-sigVer-FIPS204",
]

def say(msg):  print("\n=== " + msg + " ===", flush=True)
def info(msg): print("  " + msg, flush=True)

def need(tool):
    p = shutil.which(tool)
    if p: info(f"found {tool}: {p}")
    return p

def run(cmd, **kw):
    """Run a command, return CompletedProcess; never raises on non-zero."""
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

# ---------------------------------------------------------------------------
def step1_download():
    say("1. Download NIST ACVP vectors from usnistgov/ACVP-Server (fresh)")
    nist = WORK / "nist"; nist.mkdir(parents=True, exist_ok=True)
    for f in FOLDERS:
        url = f"{NIST_BASE}/{f}/internalProjection.json"
        dst = nist / f"{f}.json"
        info(f"fetching {f}/internalProjection.json")
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                dst.write_bytes(r.read())
        except Exception as e:
            print(f"  ERROR downloading {url}: {e}")
            print("  (check your internet connection / proxy and re-run)")
            sys.exit(1)
    return nist

def step2_hash(nist):
    say("2. SHA-256 of the downloaded NIST files (compare to the report)")
    for p in sorted(nist.glob("*.json")):
        h = hashlib.sha256(p.read_bytes()).hexdigest()
        print(f"  {h}  {p.name}")

def step3_reference():
    say("3. Clone the independent FIPS 203/204 reference (py-acvp-pqc)")
    if not need("git"):
        print("  ERROR: git not found on PATH. Install Git for Windows and re-run.")
        sys.exit(1)
    repo = WORK / "py-acvp-pqc"
    if not repo.exists():
        r = run(["git", "clone", PYACVP_URL, str(repo)])
        if r.returncode != 0:
            print("  git clone failed:\n" + r.stderr); sys.exit(1)
    # pin the commit so the reference matches the validated snapshot
    run(["git", "-C", str(repo), "checkout", "--quiet", PYACVP_COMMIT])
    head = run(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"]).stdout.strip()
    info(f"py-acvp-pqc commit: {head}")
    # ensure pycryptodome is available to THIS python (the reference needs it)
    try:
        import Crypto  # noqa: F401
    except Exception:
        info("installing pycryptodome ...")
        import importlib
        ok = False
        # plain install works on Windows/macOS; the fallbacks cover managed envs
        for extra in ([], ["--user"], ["--break-system-packages"]):
            run([sys.executable, "-m", "pip", "install", "--quiet", *extra, "pycryptodome"])
            importlib.invalidate_caches()
            try:
                import Crypto  # noqa: F401
                ok = True; break
            except Exception:
                continue
        if not ok:
            print("  ERROR: could not install pycryptodome automatically. Run:")
            print(f"     {sys.executable} -m pip install pycryptodome")
            sys.exit(1)
    return repo

def step4_screen(repo, nist):
    say("4. Screen vectors: run the reference (verbatim) -- expect 0 FAIL")
    # point the reference at OUR freshly-downloaded vectors
    jc = repo / "json-copy"
    if jc.exists():
        for f in FOLDERS:
            d = jc / f
            if d.exists():
                shutil.copy(nist / f"{f}.json", d / "internalProjection.json")
    for script in ("fips203.py", "fips204.py"):
        if (repo / script).exists():
            r = run([sys.executable, script], cwd=str(repo))
            for line in (r.stdout + r.stderr).splitlines():
                if "PASS" in line or "FAIL" in line:
                    print("  " + line)

def step5_extract(repo, nist):
    say("5. Extract NTT KATs from real ACVP KeyGen cases (public key == ACVP)")
    sys.path.insert(0, str(repo))
    cwd0 = os.getcwd(); os.chdir(repo)   # reference reads relative paths
    try:
        import importlib
        fips203 = importlib.import_module("fips203")
        fips204 = importlib.import_module("fips204")
    except Exception as e:
        os.chdir(cwd0)
        print(f"  ERROR importing reference modules: {e}")
        print("  The pinned reference API may have changed; see the commit note.")
        sys.exit(1)

    def extract(scheme, json_path, pkkey, q, width, run_keygen):
        d = json.load(open(json_path)); g = d["testGroups"][0]
        cls = fips203.ML_KEM if scheme == "kem" else fips204.ML_DSA
        inst = cls(g["parameterSet"])
        pairs = []; verified = 0
        for t in g["tests"][:8]:
            caps = []; orig = inst.ntt
            def hook(x, orig=orig, caps=caps):
                r = orig(x)
                if len(caps) < 1:
                    caps.append((list(x), list(r)))
                return r
            inst.ntt = hook
            pk = run_keygen(inst, t)
            inst.ntt = orig
            exp = t.get(pkkey)
            if exp and pk.hex().upper() == exp.upper():
                verified += 1
            pairs.append(caps[0])
        out = WORK / f"{scheme}_batch.mem"
        with open(out, "w") as fh:
            fh.write(f"{len(pairs)}\n")
            for fin, fout in pairs:
                for c in fin:  fh.write(f"{c % q:0{width}x}\n")
                for c in fout: fh.write(f"{c % q:0{width}x}\n")
        print(f"  {scheme.upper()}: {len(pairs)} KATs extracted, "
              f"{verified}/{len(pairs)} KeyGen public keys == ACVP expected")

    extract("kem", nist / "ML-KEM-keyGen-FIPS203.json", "ek", 3329, 4,
            lambda inst, t: inst.keygen_internal(bytes.fromhex(t["d"]),
                                                 bytes.fromhex(t["z"]))[0])
    extract("dsa", nist / "ML-DSA-keyGen-FIPS204.json", "pk", 8380417, 6,
            lambda inst, t: inst.keygen_internal(bytes.fromhex(t["seed"]))[0])
    os.chdir(cwd0)

def step6_simulate():
    say("6. Simulate the hardware NTT on the ACVP KATs and byte-compare")
    iv, vvp = need("iverilog"), need("vvp")
    if not (iv and vvp):
        print("  iverilog/vvp not found on PATH -- skipping the hardware step.")
        print("  Install Icarus Verilog (https://bleyer.org/icarus) and re-run")
        print("  to reproduce the 8/8 byte-exact result.")
        return
    # copy hw sources + the freshly-extracted mem files into WORK, run vvp FROM
    # WORK with SHORT relative +MEM names (avoids the path-length truncation bug)
    for name in ("pqc_ntt_mont_synth.v", "twiddle_init.vh", "tb_batch.v"):
        src = HERE / name
        if not src.exists():
            print(f"  ERROR: {name} not found next to this script."); return
        shutil.copy(src, WORK / name)
    r = run([iv, "-g2012", "-o", "batch.vvp", "pqc_ntt_mont_synth.v", "tb_batch.v"],
            cwd=str(WORK))
    if r.returncode != 0:
        print("  iverilog compile failed:\n" + r.stderr); return
    for ms, mem, label in (("0", "kem_batch.mem", "ML-KEM"),
                           ("1", "dsa_batch.mem", "ML-DSA")):
        res = run([vvp, "batch.vvp", f"+MS={ms}", f"+MEM={mem}"], cwd=str(WORK))
        for line in (res.stdout + res.stderr).splitlines():
            if "ACVP" in line or "mismatch" in line.lower():
                print(f"  [{label}] " + line.strip())

def main():
    print("reproduce.py -- NIST ACVP validation of the shared NTT engine")
    print(f"working directory: {WORK}")
    WORK.mkdir(parents=True, exist_ok=True)
    nist = step1_download()
    step2_hash(nist)
    repo = step3_reference()
    step4_screen(repo, nist)
    step5_extract(repo, nist)
    step6_simulate()
    say("DONE")
    print("If step 4 shows 0 FAIL, step 5 shows public keys == ACVP, and step 6")
    print("shows 8/8 byte-exact, you have independently reproduced the chain.")
    print("Compare the hashes in step 2 against NIST_ACVP_RAW_REPORT.txt section [1];")
    print("they will differ if NIST has updated the vectors since -- that is expected,")
    print("and the screening/extraction still validate against whatever is current.")

if __name__ == "__main__":
    main()

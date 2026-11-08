#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

VERSION = "6.11.0"
ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent


def reader(source, name):
    matches = list(re.finditer(r"^static int\n" + name + r"\([^\n]*\)\n\{.*?^\}", source, re.M | re.S))
    if len(matches) != 1:
        raise RuntimeError(f"Expected one complete {name} function; review extraction")
    return matches[0]


def check(source_dir, output, label, expected=None):
    source = (source_dir / "file.c").read_text()
    legacy = re.findall(r"typedef struct Jobrec5 Jobrec5;.*?Jobrec5size = offsetof\(Jobrec5, pad\)\n\};", source, re.S)
    if len(legacy) != 1:
        raise RuntimeError("Review Jobrec5 extraction")
    unit = output / label
    unit.mkdir()
    (unit / "readers.inc").write_text(legacy[0] + "\n" + "\n".join(
        reader(source, name).group() for name in ("readrec", "readrec5", "readfull")))
    command = ["cbmc", str(HERE / "replay.c"), "-I", str(unit), "-I", str(source_dir),
               "--64", "--unwind", "1", "--unwinding-assertions", "--trace", "--json-ui"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (unit / "result.json").write_text(result.stdout)
    (unit / "stderr.txt").write_text(result.stderr)
    (unit / "command.json").write_text(json.dumps(command, indent=2))
    data = json.loads(result.stdout)
    properties = [p for item in data for p in item.get("result", [])]
    failures = [p for p in properties if p["status"] == "FAILURE"]
    if expected is None:
        if result.returncode != 0 or not properties or failures:
            raise RuntimeError(f"{label} failed. Read {unit / 'result.json'}")
    elif result.returncode != 10 or not any(p.get("description") == expected for p in failures):
        raise RuntimeError(f"{label} did not fail its intended property. Read {unit / 'result.json'}")
    print(f"{label}: {'PASS' if expected is None else 'EXPECTED FAILURE: ' + expected}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    version = subprocess.check_output(["cbmc", "--version"], text=True).strip()
    if version.split()[0] != VERSION:
        raise RuntimeError(f"Install CBMC {VERSION}; found {version}")
    output = args.output or Path(tempfile.mkdtemp(prefix="beanstalkd-wal-proof-"))
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError("Choose an empty evidence directory")
    print(f"Evidence: {output.resolve()}", flush=True)
    prepare = ROOT / "ct-tests/prepare-source.sh"
    with (output / "prepare.log").open("w") as log:
        subprocess.run([str(prepare), str(output)], stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=120)
    sources = list(output.glob("beanstalkd-*/file.c"))
    if len(sources) != 1:
        raise RuntimeError("Expected one upstream source tree")
    source_dir = sources[0].parent
    entries = (ROOT / "patches/series").read_text().splitlines()
    inputs = [prepare, ROOT / "ct-tests/apply-patches.sh", ROOT / "patches/series", ROOT / "Dockerfile"]
    inputs.extend(ROOT / "patches" / name for name in entries)
    metadata = {"cbmc": version,
                "archive_sha256": hashlib.sha256((output / "upstream.tar.gz").read_bytes()).hexdigest(),
                "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "inputs": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}
    (output / "inputs.json").write_text(json.dumps(metadata, indent=2) + "\n")
    check(source_dir, output, "baseline")
    if args.self_test:
        path = source_dir / "file.c"
        original = path.read_text()
        guard = "if ((size_t)jr.body_size > job_data_size_limit + 2)"
        for name in ("readrec", "readrec5"):
            match = reader(original, name)
            if match.group().count(guard) != 1:
                raise RuntimeError(f"Review mutation site in {name}")
            for mutation, replacement, expected in (
                ("lost-crlf", "if ((size_t)jr.body_size > job_data_size_limit)", "legal stored size replays"),
                ("extra-byte", "if ((size_t)jr.body_size > job_data_size_limit + 3)", "oversize rejected before allocation"),
            ):
                broken = original[:match.start()] + match.group().replace(guard, replacement) + original[match.end():]
                try:
                    path.write_text(broken)
                    check(source_dir, output, f"{name}-{mutation}", expected)
                finally:
                    path.write_text(original)
        check(source_dir, output, "restored")


if __name__ == "__main__":
    main()

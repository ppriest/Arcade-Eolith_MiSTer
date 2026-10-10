#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Vendored files against their source repositories.

    python scripts/vendor_sync.py              report
    python scripts/vendor_sync.py --update     take the source's HEAD for every file that moved
    python scripts/vendor_sync.py --diff PATH  show the upstream change for one file

scripts/vendor.json lists each vendored file: the source repository (a sibling under
MISTER_CORES_ROOT), the path there, the commit it was copied at, and a mode:
  copy   the file must equal the source blob at that commit; a local edit is an error
  track  an adapted copy: upstream movement is reported, never copied; merge it by hand (or with the
         file's generator, if the file names one), then set its commit in vendor.json
Only committed upstream changes count; uncommitted ones in the source are listed as a note.
--update refuses a "copy" file with a local edit and leaves "track" files alone. After an update, rerun the benches the
roadmap names for the file (ROADMAP, Open items) before committing.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST = REPO / "scripts" / "vendor.json"
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import load_env  # noqa: E402


def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    if check and r.returncode:
        sys.exit(f"git -C {repo} {' '.join(args)}: {r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def source_root(name, sources):
    root = Path(load_env().get("MISTER_CORES_ROOT") or REPO.parent)
    return root / sources[name]["repo"]


def local_blob(path):
    p = REPO / path
    if not p.exists():
        return None
    return git(REPO, "hash-object", f"--path={path}", str(p)).decode().strip()


def blob(repo, rev, path):
    r = git(repo, "rev-parse", f"{rev}:{path}", check=False)
    return r.decode().strip() or None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--diff", metavar="PATH")
    a = ap.parse_args()
    man = json.loads(MANIFEST.read_text(encoding="utf-8"))
    sources = man["sources"]
    bad = moved = 0
    if a.diff:
        f = next((f for f in man["files"] if f["path"] == a.diff), None)
        if not f:
            sys.exit(f"{a.diff} is not in {MANIFEST.name}")
        repo = source_root(f["source"], sources)
        sys.stdout.write(git(repo, "diff", f["commit"], "HEAD", "--", f.get("from", f["path"])).decode(errors="replace"))
        return
    for f in man["files"]:
        repo = source_root(f["source"], sources)
        frm = f.get("from", f["path"])
        pinned = blob(repo, f["commit"], frm)
        head = blob(repo, "HEAD", frm)
        loc = local_blob(f["path"])
        notes = []
        if loc is None:
            notes.append("MISSING locally")
            bad += 1
        elif f["mode"] == "copy" and loc != pinned:
            notes.append("LOCAL EDIT of a copy")
            bad += 1
        if head != pinned:
            n = len(git(repo, "log", "--oneline", f"{f['commit']}..HEAD", "--", frm).splitlines())
            notes.append(f"upstream moved ({n} commit{'s' if n != 1 else ''})")
            moved += 1
            if a.update and f["mode"] == "copy" and loc in (None, pinned):
                (REPO / f["path"]).parent.mkdir(parents=True, exist_ok=True)
                (REPO / f["path"]).write_bytes(git(repo, "show", f"HEAD:{frm}"))
                f["commit"] = git(repo, "rev-parse", "HEAD").decode().strip()
                notes.append("updated")
        if git(repo, "status", "--porcelain", "--", frm).strip():
            notes.append("uncommitted change in the source (ignored)")
        print(f"{f['path']:42s} {f['mode']:5s} {f['commit'][:9]}  {'; '.join(notes) or 'ok'}")
    if a.update:
        MANIFEST.write_text(json.dumps(man, indent=2) + "\n", encoding="utf-8")
    print(f"{len(man['files'])} files, {bad} with errors, {moved} moved upstream")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

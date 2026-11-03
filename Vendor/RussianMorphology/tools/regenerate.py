#!/usr/bin/env python3
"""Rebuild the lexical tables from exact local upstream Git objects, without downloads.

Pass three checkouts containing the revisions in dictionary-manifest.json.
The default verifies byte equality. --write updates only the six lexical tables.
Generator executables, copied sources and temporary data are joined and deleted.
"""
from pathlib import Path
import argparse
import io
import hashlib
import json
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def archive(checkout, revision, destination):
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", revision], text=True).strip()
    if actual != revision:
        raise ValueError("Expected an immutable full revision: " + revision)
    data = subprocess.check_output(["git", "-C", str(checkout), "archive", revision])
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as source:
        source.extractall(destination, filter="data")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("libmorph", "moonycode", "mtc"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "dictionary-manifest.json").read_text())
    with tempfile.TemporaryDirectory(prefix="pichi-morphology-generation-") as temporary:
        task_root = Path(temporary)
        source = task_root / "libmorph"
        archive(args.libmorph, manifest["libmorphRevision"], source)
        archive(args.moonycode, manifest["moonycodeRevision"], task_root / "moonycode")
        archive(args.mtc, manifest["mtcGeneratorRevision"], source / "contrib/mtc")
        # Generator-only portability fix: Apple's LP64 size_t is unsigned long,
        # whereas uint64_t is unsigned long long. Without these overloads mtc's
        # generic serialization recurses forever. Runtime code does not use mtc.
        header = source / "contrib/mtc/serialize.h"
        anchor = "/*\n * C strings serialization/deserialization specializations\n */"
        text = header.read_text()
        assert text.count(anchor) == 1
        patch = """#if defined(__APPLE__) && defined(__LP64__)
template <> inline size_t GetBufLen(const unsigned long& i) { return mtc::integers::len(i); }
template <class O> O* Serialize(O* o, const unsigned long& i) { return mtc::integers::put(o, i); }
template <class S> S* FetchFrom(S* s, unsigned long& i) { return mtc::integers::get(s, i); }
template <class S> S* SkipToEnd(S* s, const unsigned long*) { return mtc::integers::end(s, (const unsigned long*)nullptr); }
#endif

"""
        header.write_text(text.replace(anchor, patch + anchor))
        output = task_root / "generated"
        tables = output / "dictree"
        tables.mkdir(parents=True)
        common = ["clang++", "-std=c++17", "-O2", "-DNAMESPACE=libmorph::rus",
                  "-I" + str(source), "-I" + str(source / "contrib"), "-I" + str(task_root)]
        xlat = [str(path) for path in sorted((task_root / "moonycode/xlat").glob("*.cpp"))]
        tools = {
            "tfc": ["utils/tfc/ftable.cpp", "utils/tfc/gramap.cpp", "utils/tfc/tfc.cpp"],
            "makeich": ["lang-rus/libdict/tools/makeich/makeich.cpp"],
            "buildic": ["lang-rus/libdict/tools/buildic/" + name for name in
                        ("lresolve.cpp", "makerus.cpp", "mtables.cpp")],
        }
        for name, files in tools.items():
            subprocess.run(common + [str(source / path) for path in files] + xlat +
                           ["-o", str(output / name)], check=True)
        commands = [
            [str(output / "tfc"), "-lang:rus", str(source / "lang-rus/tables/flextabs.tf"),
             str(output / "flextabs.btf"), str(output / "flextabs.sym")],
            [str(output / "makeich"), str(source / "lang-rus/tables/mtables.mx"),
             str(output / "interchg.bmx"), str(output / "interchg.sym")],
            [str(output / "buildic"), "-flex-table=" + str(output / "flextabs.btf"),
             "-flex-index=" + str(output / "flextabs.sym"), "-intr-table=" + str(output / "interchg.bmx"),
             "-intr-index=" + str(output / "interchg.sym"), "-target-dir=" + str(tables),
             "-unknown=" + str(output / "unknown.txt"), "-namespace=libmorph::rus"] +
            [str(path) for path in sorted((source / "lang-rus/dict").glob("*.dic"))],
        ]
        for command in commands:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for name in manifest["data"]:
            text = (tables / (Path(name).stem + ".cpp")).read_text()
            match = re.search(r"unsigned char (\w+)\[\]\s*=\s*\{([^}]+)\}", text, re.S)
            if not match or match[1] != Path(name).stem:
                raise ValueError("Unexpected generated source: " + name)
            data = bytes(int(value, 16) for value in re.findall(r"0x([a-fA-F0-9]{2})", match[2]))
            target = ROOT / "Sources/CRussianMorphology/Data" / name
            if args.write:
                target.write_bytes(data)
                manifest["data"][name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            elif target.read_bytes() != data:
                raise ValueError("Generated lexical table differs: " + name)
            print(name, len(data), "bytes verified" if not args.write else "bytes written")
        if args.write:
            digest = hashlib.sha256(json.dumps(manifest["data"], sort_keys=True,
                                               separators=(",", ":")).encode()).hexdigest()
            manifest["resourceIdentity"] = "libmorph-russian-v1/" + digest
            manifest["dictionaryBytes"] = sum(item["bytes"] for item in manifest["data"].values())
            (ROOT / "dictionary-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
            swift = ROOT / "Sources/PichiRussianMorphology/SensitiveDictionaryMorphologySnapshot.swift"
            text = swift.read_text()
            text, replacements = re.subn(r'public static let resourceIdentity = "[^"]+"',
                'public static let resourceIdentity = "' + manifest["resourceIdentity"] + '"', text)
            assert replacements == 1
            swift.write_text(text)


if __name__ == "__main__":
    main()

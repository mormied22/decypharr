"""Small, local CI receipts; no credentials, registry writes or lab connections."""
import json
import re
import sys
from pathlib import Path

SENSITIVE = re.compile(r"token|api.?key|secret|password|authorization|cookie", re.I)


def redact(line):
    return "[sensitive diagnostic omitted]\n" if SENSITIVE.search(line) else line


def tests(directory, name):
    path = directory / (name + ".jsonl")
    failed_packages, failed_tests, output = set(), set(), []
    for line in path.read_text(errors="replace").splitlines(keepends=True):
        try:
            event = json.loads(line)
        except ValueError:
            output.append(redact(line))
            continue
        if event.get("Action") == "fail":
            if event.get("Test"):
                failed_tests.add((event.get("Package", ""), event["Test"]))
            else:
                failed_packages.add(event.get("Package", ""))
        if "Output" in event:
            event["Output"] = redact(event["Output"])
        output.append(json.dumps(event) + "\n")
    path.write_text("".join(output))
    return {
        "exitCode": int((directory / (name + ".exit")).read_text().strip()),
        "failedPackages": sorted(failed_packages),
        "failedTests": [{"package": package, "test": test} for package, test in sorted(failed_tests)],
    }


def main():
    if sys.argv[1:] == ["--redact"]:
        for line in sys.stdin:
            sys.stdout.write(redact(line))
        return
    directory = Path(sys.argv[1])
    pins = json.loads(Path("build/owned-baseline-inputs.json").read_text())
    labels = json.loads((directory / "labels.json").read_text())
    metadata = json.loads((directory / "build-metadata.json").read_text())
    revision = (directory / "build-revision.txt").read_text().strip()
    expected = {
        "org.opencontainers.image.source": "https://github.com/mormied22/decypharr",
        "org.opencontainers.image.revision": revision,
        "org.opencontainers.image.version": "2.7-linkfix",
        "org.opencontainers.image.created": (directory / "build-date.txt").read_text().strip(),
        "org.opencontainers.image.base.name": "docker.io/library/alpine:3.24.1",
        "org.opencontainers.image.base.digest": pins["images"][2]["digest"],
        "io.mormied22.decypharr.code.revision": pins["codeCommit"],
        "io.mormied22.decypharr.patch.origin": pins["patchOrigin"],
    }
    label_matches = all(labels.get(name) == value for name, value in expected.items())
    focused = tests(directory / "test-results", "link")
    full = tests(directory / "test-results", "full-suite")
    digest = metadata.get("containerimage.digest", "")
    image_id = (directory / "image-id.txt").read_text().strip()
    digest_ok = bool(re.fullmatch(r"sha256:[a-f0-9]{64}", digest))
    config_ok = image_id == metadata.get("containerimage.config.digest")
    platform = (directory / "platform.txt").read_text().strip()
    http_status = int((directory / "http-status.txt").read_text().strip())
    receipt = {
        "sourceRevision": revision, "codeRevision": pins["codeCommit"],
        "localImage": pins["localImage"], "manifestDigest": digest, "imageId": image_id,
        "platform": platform, "labels": labels, "labelsVerified": label_matches,
        "manifestDigestPresent": digest_ok, "configDigestMatches": config_ok,
        "applicationCgoEnabled": 1, "healthcheckCgoEnabled": 0,
        "focusedTests": focused, "fullSuite": full,
        "httpSmoke": {"port": 8282, "finalStatus": http_status, "emptyInitialConfig": True,
                      "debridCredentialsProvided": False, "network": "none", "publishedPorts": False},
        "registryLogin": False, "registryPush": False, "labAccess": False,
        "unpinnedInputs": pins["unpinned"],
    }
    passed = label_matches and digest_ok and config_ok and platform == "linux/amd64" and http_status == 200 and focused["exitCode"] == 0 and full["exitCode"] == 0
    receipt["acceptancePassed"] = passed
    (directory / "acceptance.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        raise SystemExit("Owned baseline acceptance has failures; inspect the retained receipt and test logs.")


if __name__ == "__main__":
    main()

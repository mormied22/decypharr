# Owned Linkfix baseline build

This branch keeps Go source, `go.mod` and `go.sum` exactly at
`bc6e64b3374aa80a92127c8ff570ebb1fb9c5568`. It changes build/CI infrastructure
only. The owned build source is `mormied22/decypharr`; the recovered patch origin
is `h1n054ur/decypharr`. Original licence and author history remain unchanged.

`build/owned-baseline-inputs.json` records publisher URLs, checked index and
linux/amd64 manifest digests, rclone checksums, action revisions and APK lists.
The Go application remains CGO enabled, with the original xx toolchain and
version/channel linker variables. The healthcheck remains CGO disabled.

## Manual Linux acceptance

Use the existing `release.yml` workflow on `maintenance/linkfix-2.7-build` via
`workflow_dispatch`. It has read-only repository permission, no registry login,
no image push and no automatic trigger. The inherited beta/docs publishing files
are manual notices only. The local-only image tag is:

```text
decypharr:2.7-linkfix-bc6e64b-owned.1
```

On an explicitly authorised Linux Docker machine, the equivalent command is:

```sh
bash build/owned-baseline-acceptance.sh
```

It checks the unchanged Go diff, exports focused/full CGO Linux test results,
builds and loads the image, verifies actual OCI labels and both manifest/config
digests, records installed APK/rclone versions, and probes HTTP8282 with a new
empty config directory. The probe container has no external network or published
ports and receives no debrid credentials. It is stopped on exit. Only receipts
and redacted diagnostics are uploaded; generated config/auth files are excluded.
Any focused/full test failure, label/digest mismatch or HTTP failure fails the
acceptance gate. Failures are retained rather than silently skipped.

## Pinning limits

Base image content and rclone bytes are pinned, and Go dependencies retain their
existing checksum lock. Alpine repository indexes and resolved/transitive APK
package versions still move; acceptance records the installed versions. The
GitHub runner image, host kernel and Docker/Buildx/BuildKit versions also move
and are recorded. The build date and build-branch revision are explicit inputs.
No bit-identical reconstruction of the running production executable, security
certification, production playback test or performance claim is made.

The source inputs were read from Docker's official registry manifests and
`https://downloads.rclone.org/v1.76.0/SHA256SUMS`. Registry reads used anonymous
pull metadata only; there is no `docker login`. Checksums were fetched over TLS;
an independent signature-verification step was not added. Only linux/amd64 is
accepted by this job; retained ARM download checksums do not establish ARM tests.

No production image, compose file or lab service is changed by this branch.
Before a future deployment, follow the document-only rollback preservation
procedure in the shared vault's Decypharr project note. Deployment and registry
publication require separate authorization.

#!/bin/sh
# Invoked only in the optional acceptance-tests Docker stage.
set -u
mkdir -p /acceptance
go version > /acceptance/go-version.txt
apk info -v > /acceptance/builder-apk.txt
printf '%s\n' 'CGO_ENABLED=1 xx-go test -json -count=1 -timeout=3m ./pkg/manager/link/...' > /acceptance/test-commands.txt
CGO_ENABLED=1 xx-go test -json -count=1 -timeout=3m ./pkg/manager/link/... > /acceptance/link.jsonl 2>&1
printf '%s\n' "$?" > /acceptance/link.exit
printf '%s\n' 'CGO_ENABLED=1 xx-go test -json -count=1 -timeout=8m ./...' >> /acceptance/test-commands.txt
CGO_ENABLED=1 xx-go test -json -count=1 -timeout=8m ./... > /acceptance/full-suite.jsonl 2>&1
printf '%s\n' "$?" > /acceptance/full-suite.exit
# Export evidence even when a test fails; the host acceptance script fails its gate.
exit 0

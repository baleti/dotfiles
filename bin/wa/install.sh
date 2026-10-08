#!/usr/bin/env bash
# Build wa and install it to ~/.local/bin (on PATH for agents and systemd units).
set -euo pipefail
cd "$(dirname "$0")"
go vet ./...
go test ./...
go build -trimpath -o "$HOME/.local/bin/wa.new" .
mv -f "$HOME/.local/bin/wa.new" "$HOME/.local/bin/wa"
echo "installed $(command -v wa) ($(go list -m -f '{{.Version}}' go.mau.fi/whatsmeow))"

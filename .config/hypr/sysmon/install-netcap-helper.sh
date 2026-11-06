#!/bin/sh
# One-time (re)install of the privileged packet-metadata helper. Only needed
# when netcap-helper/ itself changes -- NOT when sysmond is rebuilt.
#   - runs the helper's full test suite first (aborts on any failure)
#   - installs it root-owned in a root-owned dir, then grants ONLY cap_net_raw
set -eu
cd "$(dirname "$0")/netcap-helper"
cargo test --release --locked
cargo build --release --locked
BIN=target/release/netcap-helper
DIR=/usr/local/lib/sysmon
DEST=$DIR/netcap-helper
echo "installing: $(sha256sum "$BIN")"
sudo install -d -o root -g root -m 0755 "$DIR"
sudo install -o root -g root -m 0755 "$BIN" "$DEST"
sudo setcap cap_net_raw+ep "$DEST"
echo "installed: $(getcap "$DEST")"
echo "verify: $(dirname "$0")/../target/release/netcap-probe 3   (then: systemctl --user restart sysmond)"

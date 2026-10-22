#!/usr/bin/env bash
# Runs the DSL conformance suite (tests.json) against every implementation that can run it from here.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
python3 "$here/test_dsl.py" || rc=1
( cd "$here" && QML_XHR_ALLOW_FILE_READ=1 QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen timeout 30 qml6 test_qml.qml 2>&1 | tee /dev/stderr | grep -q ': ok$' ) || rc=1
( cd ~/bin/index/images && cargo test --release dsl_conformance 2>&1 | grep -E '^test result' ) || rc=1
exit $rc

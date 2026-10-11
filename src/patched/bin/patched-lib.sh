# shared helpers; sourced
ROOT=${PATCHED_ROOT:-$HOME/src/patched}
STAGING=$ROOT/staging
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/patched
mkdir -p "$STAGING" "$STATE"

registry_files() { ls "$ROOT"/registry/*.sh 2>/dev/null; }

load_entry() {   # load_entry <file>
  unset NAME PKG UPSTREAM_URL TAG_GLOB BRANCH DEPS PATCH_NOTES
  # shellcheck disable=SC1090
  . "$1"
  CHECKOUT=$ROOT/$NAME
  BUILD=$ROOT/build/$NAME
}

deps_fingerprint() {   # versions of the DEPS as installed right now
  # shellcheck disable=SC2086
  pacman -Q $DEPS 2>&1 | sort | sha256sum | cut -d' ' -f1
}

latest_tag() { git -C "$CHECKOUT" tag --list "$TAG_GLOB" --sort=-version:refname | head -1; }
base_tag()   { git -C "$CHECKOUT" describe --tags --abbrev=0 "$BRANCH" 2>/dev/null; }

build_pkg() {   # builds the current $BRANCH into $STAGING; prints the package path
  (
    cd "$BUILD" || exit 1
    rm -rf src pkg
    PKGDEST=$STAGING makepkg -f --noconfirm --nocheck >"$STATE/$NAME.build.log" 2>&1
  ) || return 1
  ls -t "$STAGING/$PKG"-*.pkg.tar.zst 2>/dev/null | head -1
}

status_set() { printf '%s\n' "$2" >"$STATE/$1.status"; }

# keep a plain-text copy of the patch commits in the tracked tree (checkouts are gitignored)
export_patches() {   # needs load_entry; <upstream tag>..$BRANCH -> patches/$NAME/
  local tag; tag=$(base_tag) || return 0
  rm -rf "$ROOT/patches/$NAME"; mkdir -p "$ROOT/patches/$NAME"
  git -C "$CHECKOUT" format-patch -q --no-signature -o "$ROOT/patches/$NAME" "$tag..$BRANCH" >/dev/null
}

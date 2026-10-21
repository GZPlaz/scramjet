#!/usr/bin/env bash
# Production build used by buildpack-based hosts (Koyeb, Heroku, ...).
# Installs the rewriter toolchain if it is missing, builds scramjet and
# the demo frontend, then cleans up so the final image stays small.
set -euo pipefail
shopt -s inherit_errexit

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WASM_BINDGEN_VERSION="0.2.105"
BINARYEN_VERSION="${BINARYEN_VERSION:-version_124}"

# keep the toolchain outside the app directory so it doesn't end up in the image
TOOLCHAIN_DIR="${SCRAMJET_TOOLCHAIN_DIR:-${TMPDIR:-/tmp}/scramjet-toolchain}"
if ! command -v rustup &>/dev/null; then
	export CARGO_HOME="$TOOLCHAIN_DIR/cargo"
	export RUSTUP_HOME="$TOOLCHAIN_DIR/rustup"
	export PATH="$CARGO_HOME/bin:$PATH"
fi
export PATH="$TOOLCHAIN_DIR/bin:$PATH"
mkdir -p "$TOOLCHAIN_DIR/bin"

log() {
	echo "-----> $*"
}

download() {
	curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$1"
}

install_rust() {
	if ! command -v rustup &>/dev/null; then
		log "Installing rustup"
		download https://sh.rustup.rs | sh -s -- -y --profile minimal \
			--default-toolchain none --no-modify-path
	fi
	log "Installing nightly Rust toolchain"
	rustup toolchain install nightly --profile minimal \
		--component rust-src --target wasm32-unknown-unknown
}

install_wasm_bindgen() {
	if command -v wasm-bindgen &>/dev/null &&
		[[ "$(wasm-bindgen -V)" =~ ^"wasm-bindgen $WASM_BINDGEN_VERSION" ]]; then
		return
	fi
	log "Installing wasm-bindgen $WASM_BINDGEN_VERSION"
	local name="wasm-bindgen-$WASM_BINDGEN_VERSION-x86_64-unknown-linux-musl"
	if [ "$(uname -m)" = "x86_64" ] &&
		download "https://github.com/wasm-bindgen/wasm-bindgen/releases/download/$WASM_BINDGEN_VERSION/$name.tar.gz" |
		tar -xz -C "$TOOLCHAIN_DIR/bin" --strip-components=1 "$name/wasm-bindgen"; then
		return
	fi
	cargo +nightly install wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION"
}

install_binaryen() {
	if command -v wasm-opt &>/dev/null; then
		return
	fi
	log "Installing binaryen $BINARYEN_VERSION"
	local arch
	case "$(uname -m)" in
	x86_64) arch="x86_64" ;;
	aarch64 | arm64) arch="aarch64" ;;
	*)
		echo "Unsupported architecture for binaryen: $(uname -m)"
		exit 1
		;;
	esac
	mkdir -p "$TOOLCHAIN_DIR/binaryen"
	download "https://github.com/WebAssembly/binaryen/releases/download/$BINARYEN_VERSION/binaryen-$BINARYEN_VERSION-$arch-linux.tar.gz" |
		tar -xz -C "$TOOLCHAIN_DIR/binaryen" --strip-components=1
	ln -sf "$TOOLCHAIN_DIR/binaryen/bin/wasm-opt" "$TOOLCHAIN_DIR/bin/wasm-opt"
}

install_wasm_snip() {
	if command -v wasm-snip &>/dev/null; then
		return
	fi
	log "Installing wasm-snip"
	cargo +nightly install --git https://github.com/r58playz/wasm-snip
}

# the buildpack may have installed with NODE_ENV=production; the build needs devDependencies
if ! [ -x node_modules/.bin/rspack ]; then
	log "Installing devDependencies"
	NODE_ENV=development pnpm install --frozen-lockfile
fi

install_rust
install_wasm_bindgen
install_binaryen
install_wasm_snip

log "Building rewriter"
(cd packages/core && RELEASE="${RELEASE:-1}" pnpm rewriter:build)

log "Building scramjet"
(cd packages/core && pnpm build)

# VITE_WISP_URL is optional: without it the demo uses the wisp server
# on the same origin (see deploy/server.js)
log "Building demo"
(cd packages/demo && pnpm build)

# the rust build directory is several GB and isn't needed at runtime
log "Cleaning up build artifacts"
rm -rf packages/core/rewriter/target

log "Build complete"

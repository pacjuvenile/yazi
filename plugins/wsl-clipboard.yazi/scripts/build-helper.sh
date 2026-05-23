#!/usr/bin/env sh
set -eu

script="$0"
case "$script" in
	/*) ;;
	*) script="$(pwd)/$script" ;;
esac
root="$(cd "$(dirname "$script")/.." && pwd)"

if [ "${WSL_CLIPBOARD_BUILD_HELPER_IN_NIX:-0}" != "1" ]; then
	if command -v nix >/dev/null 2>&1; then
		nixpkgs="${WSL_CLIPBOARD_NIXPKGS:-nixpkgs}"
		export WSL_CLIPBOARD_BUILD_HELPER_IN_NIX=1
		exec nix shell \
			"$nixpkgs#rustup" \
			"$nixpkgs#pkgsCross.mingwW64.stdenv.cc" \
			"$nixpkgs#pkgsCross.mingwW64.windows.pthreads" \
			-c "$script" "$@"
	fi
fi

cd "$root"

target="x86_64-pc-windows-gnu"
export RUSTUP_HOME="${RUSTUP_HOME:-$root/.cache/rustup}"
export CARGO_HOME="${CARGO_HOME:-$root/.cache/cargo}"
export PATH="$CARGO_HOME/bin:$PATH"

pthread_lib="$(find /nix/store -path "*mingw_w64-pthreads*" -name libpthread.a | head -n 1 || true)"

if [ -z "$pthread_lib" ]; then
	echo "libpthread.a not found; run this script through nix shell with pkgsCross.mingwW64.windows.pthreads" >&2
	exit 1
fi

pthread_dir="$(dirname "$pthread_lib")"

export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="${CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER:-x86_64-w64-mingw32-gcc}"
export RUSTFLAGS="${RUSTFLAGS:-} -L native=$pthread_dir"

rustup toolchain install stable --profile minimal >/dev/null 2>&1 || true
rustup target add "$target" >/dev/null 2>&1 || true
rustup run stable cargo build --manifest-path helper/Cargo.toml --release --target "$target"

mkdir -p bin
cp "helper/target/$target/release/wsl-clipboard-yazi.exe" bin/

sha256sum bin/wsl-clipboard-yazi.exe

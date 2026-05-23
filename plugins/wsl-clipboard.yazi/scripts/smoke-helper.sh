#!/usr/bin/env sh
set -eu

script="$0"
case "$script" in
	/*) ;;
	*) script="$(pwd)/$script" ;;
esac
root="$(cd "$(dirname "$script")/.." && pwd)"
plugin_dir="${YAZI_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/yazi}/plugins/wsl-clipboard.yazi"
helper="${WSL_CLIPBOARD_YAZI_HELPER:-}"
if [ -z "$helper" ] && [ -f "$root/bin/wsl-clipboard-yazi.exe" ]; then
	helper="$root/bin/wsl-clipboard-yazi.exe"
fi
if [ -z "$helper" ]; then
	helper="$plugin_dir/bin/wsl-clipboard-yazi.exe"
fi
tmp="${TMPDIR:-/tmp}/wsl-clipboard-yazi-smoke-$$.txt"
trap 'rm -f "$tmp"' EXIT

printf 'wsl-clipboard-yazi helper smoke\n' >"$tmp"
win_tmp="$(wslpath -w "$tmp")"

echo "helper=$helper"
"$helper" version
"$helper" --trace diagnose
"$helper" --trace clear
payload_len="$(printf '%s\0' "$win_tmp" | wc -c | tr -d ' ')"
payload_b64="$(printf '%s\0' "$win_tmp" | base64 | tr -d '\n')"
"$helper" --trace write-files --copy --payload-base64 "$payload_b64"
"$helper" --trace read-paste
"$helper" --trace clear-owned --copy --payload-base64 "$payload_b64"

printf '%s\0' "$win_tmp" | "$helper" --trace write-files --copy --stdin-len "$payload_len"
printf '%s\0' "$win_tmp" | "$helper" --trace clear-owned --copy --stdin-len "$payload_len"

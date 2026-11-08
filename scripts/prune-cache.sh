#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Keep a Zig cache under a size limit. The compiler's cache grows without
# bound: every changed source makes a new entry, and a test binary alone is
# a quarter of a gigabyte, so weeks of building fill a disk and the build
# dies with "No space left on device" mid-stage.
#
# The cache holds three kinds of entry: o/<hash>/ a step's output, h/<hash>.txt
# the manifest naming the inputs that produced it, z/<hash> the build system's
# step state. An entry is reconstructible, so removing one costs only the time
# to build it again - but an output removed while its manifest stays breaks the
# cache for good: the next build reports "FileNotFound" for the missing file
# instead of building it again. So manifests go at least as readily as outputs:
# outputs are removed up to a cutoff, manifests and step state up to an hour
# past it (a manifest is written right after the output it describes, so one
# that survives still has its output). A manifest without its output is a
# plain miss, and the orphaned output is removed by a later pass.
#
# Nothing but o/, h/, z/ and tmp/ is touched - c/ is tiny and raster/ holds
# the raster tests' images. Mtimes are creation times (a cache hit refreshes
# nothing), so the oldest entries go first.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cache=$root/.zig-cache
limit=${ZIG_CACHE_LIMIT:-64G}
keep=75          # prune down to this percent of the limit
min_age=120      # never touch an entry younger than this many minutes
margin=3600      # seconds a manifest may outlive the output cutoff
interval=0       # skip the check when the last one was this recent (minutes)
dry=
quiet=

usage() {
    cat <<USAGE
usage: ${0##*/} [--limit SIZE] [--dir PATH] [--interval MIN] [--dry-run] [--quiet]

  --limit SIZE     cache size to stay under (default $limit, or \$ZIG_CACHE_LIMIT);
                   K, M, G, T suffixes, powers of 1024
  --dir PATH       the cache to prune (default $cache)
  --keep PERCENT   prune down to this much of the limit (default $keep)
  --min-age MIN    never remove an entry younger than this (default $min_age)
  --interval MIN   do nothing if the last run was less than this long ago
  --dry-run        report what would go, remove nothing
  --quiet          say nothing unless something was removed

The global cache is a cache of the same shape: --dir ~/.cache/zig --limit 8G
(its p/, the fetched packages, is left alone).
USAGE
}

while [ $# -gt 0 ]; do
    case $1 in
        --limit) limit=$2; shift 2 ;;
        --dir) cache=$2; shift 2 ;;
        --keep) keep=$2; shift 2 ;;
        --min-age) min_age=$2; shift 2 ;;
        --interval) interval=$2; shift 2 ;;
        --dry-run | -n) dry=1; shift ;;
        --quiet | -q) quiet=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "${0##*/}: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -d "$cache" ] || exit 0

# One pruner at a time, and never while a build might be reading the cache.
if [ -z "${ZIG_PRUNE_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
    ZIG_PRUNE_LOCKED=1 export ZIG_PRUNE_LOCKED
    set -- --limit "$limit" --dir "$cache" --keep "$keep" \
        --min-age "$min_age" --interval "$interval"
    [ -z "$dry" ] || set -- "$@" --dry-run
    [ -z "$quiet" ] || set -- "$@" --quiet
    flock -n "$cache" "$0" "$@" || :
    exit 0
fi

stamp=$cache/.prune-stamp
if [ "$interval" -gt 0 ] && [ -n "$(find "$stamp" -newermt "-$interval minutes" 2>/dev/null)" ]; then
    exit 0
fi
[ -n "$dry" ] || : >"$stamp" 2>/dev/null || :

bytes() {
    echo "$1" | awk '
        /[0-9]$/   { print $0 + 0; exit }
        /[kK]$/    { print $0 * 1024; exit }
        /[mM]$/    { print $0 * 1024 * 1024; exit }
        /[gG]$/    { print $0 * 1024 * 1024 * 1024; exit }
        /[tT]$/    { print $0 * 1024 * 1024 * 1024 * 1024; exit }
                   { print "bad"; exit }'
}

human() {
    echo "$1" | awk '{
        n = $1; u = "B"
        split("KiB MiB GiB TiB", s, " ")
        for (i = 1; i <= 4 && n >= 1024; i++) { n /= 1024; u = s[i] }
        printf (n < 10 && u != "B") ? "%.1f %s\n" : "%.0f %s\n", n, u
    }'
}

max=$(bytes "$limit")
case $max in bad | 0) echo "${0##*/}: bad size $limit" >&2; exit 2 ;; esac
target=$((max / 100 * keep))

total=$(du -s --block-size=1 "$cache" | cut -f1)
if [ "$total" -le "$max" ]; then
    [ -n "$quiet" ] || echo "${cache##*/}: $(human "$total") of a $(human "$max") limit, nothing to prune"
    exit 0
fi

# A build reading this cache: a compiler whose working directory is in the
# tree the cache belongs to. A build in another checkout has its own cache
# and does not count. Removing an entry under a running build would fail
# that build, so the pruning waits for the next run instead.
tree=${cache%/*}
busy() {
    for proc in /proc/[0-9]*; do
        exe=$(readlink "$proc/exe" 2>/dev/null) || continue
        case ${exe##*/} in zig) ;; *) continue ;; esac
        [ "${cache##*/}" = .zig-cache ] || return 0
        cwd=$(readlink "$proc/cwd" 2>/dev/null) || continue
        case $cwd in "$tree" | "$tree"/*) return 0 ;; esac
    done
    return 1
}

if busy; then
    [ -n "$quiet" ] || echo "${cache##*/}: $(human "$total") over the limit, but a build is running - left alone"
    exit 0
fi

need=$((total - target))
list=$(mktemp) || exit 1
trap 'rm -f "$list"' EXIT

# size, mtime and path of every output, oldest first, down to what must go.
find "$cache/o" -mindepth 1 -maxdepth 1 ! -newermt "-$min_age minutes" -print0 2>/dev/null |
    xargs -0 -r du -s --block-size=1 --time --time-style=+%s -- 2>/dev/null |
    sort -t "$(printf '\t')" -k2,2n |
    awk -F "$(printf '\t')" -v need="$need" '
        { freed += $1; cut = $2; print $3 }
        freed >= need { exit }
        END { printf "%d\t%d\n", freed, cut > "/dev/stderr" }' 2>"$list.cut" >"$list"

freed=$(cut -f1 "$list.cut" 2>/dev/null || echo 0)
cut=$(cut -f2 "$list.cut" 2>/dev/null || echo 0)
rm -f "$list.cut"
gone=$(wc -l <"$list" | tr -d ' ')

if [ "${cut:-0}" -eq 0 ]; then
    echo "${cache##*/}: $(human "$total") over the $(human "$max") limit, but nothing old enough to remove" >&2
    exit 0
fi

if [ -n "$dry" ]; then
    echo "${cache##*/}: $(human "$total") over the $(human "$max") limit"
    echo "would remove $gone outputs written up to $(date -d "@$cut" '+%d.%m.%Y %H:%M'), $(human "$freed")"
    echo "with the manifests and step state written up to $(date -d "@$((cut + margin))" '+%d.%m.%Y %H:%M')"
    exit 0
fi

tr '\n' '\0' <"$list" | xargs -0 -r rm -rf --
find "$cache/h" -maxdepth 1 -type f -name '*.txt' ! -newermt "@$((cut + margin))" -delete 2>/dev/null || :
find "$cache/z" -maxdepth 1 -type f ! -newermt "@$((cut + margin))" -delete 2>/dev/null || :
find "$cache/tmp" -mindepth 1 -maxdepth 1 ! -newermt '-1 day' -exec rm -rf -- {} + 2>/dev/null || :

left=$(du -s --block-size=1 "$cache" | cut -f1)
echo "${cache##*/}: was $(human "$total"), over the $(human "$max") limit; removed $gone entries, now $(human "$left")"

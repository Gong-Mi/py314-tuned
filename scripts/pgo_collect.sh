#!/bin/sh
# Inspect / merge the profraw files written by the instrumented build.
#
#   pgo_collect.sh [dir]           # show count, size, newest files
#   pgo_collect.sh [dir] --merge   # merge into <dir>/py.profdata
#   pgo_collect.sh [dir] --prune   # merge, then delete the raw files
#
# Default dir: $HOME/py314-tuned/work/pgo-profile
set -eu
DIR=${1:-$HOME/py314-tuned/work/pgo-profile}
MODE=${2:-}

[ -d "$DIR" ] || { echo "no profile dir: $DIR" >&2; exit 1; }
COUNT=$(find "$DIR" -name '*.profraw' | wc -l)
SIZE=$(du -sh "$DIR" 2>/dev/null | cut -f1)
echo "dir:    $DIR"
echo "raw:    $COUNT files, $SIZE"
[ "$COUNT" -gt 0 ] && find "$DIR" -name '*.profraw' -newer "$DIR" 2>/dev/null | head -0
[ "$COUNT" -gt 0 ] && ls -t "$DIR"/*.profraw 2>/dev/null | head -3

case "$MODE" in
  --merge|--prune)
    [ "$COUNT" -gt 0 ] || { echo "nothing to merge" >&2; exit 1; }
    OUT=$DIR/py.profdata
    echo "merging -> $OUT"
    llvm-profdata merge -o "$OUT" "$DIR"/*.profraw
    llvm-profdata show --counts "$OUT" | head -3
    if [ "$MODE" = "--prune" ]; then
      find "$DIR" -name '*.profraw' -delete
      echo "pruned raw files"
    fi
    ;;
  "") ;;
  *) echo "unknown option: $MODE" >&2; exit 2 ;;
esac

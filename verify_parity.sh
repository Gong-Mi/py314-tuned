#!/bin/sh
# Compare the built interpreter against the distro python (feature surface only,
# no performance claim). Usage: ./verify_parity.sh [prefix] [python-binary]
set -u
PREFIX_DIR=${1:-$PREFIX/opt/py314tuned}
NEW=$PREFIX_DIR/bin/python3.14
STOCK=$PREFIX/bin/python3.14
[ -x "$NEW" ] || { echo "not built: $NEW" >&2; exit 1; }
# bionic ignores DT_RPATH/DT_RUNPATH, so force the private libpython.
NEWRUN="env LD_LIBRARY_PATH=$PREFIX_DIR/lib $NEW"

echo "== versions"
"$STOCK" -VV | head -1
eval $NEWRUN -VV | head -1

echo "== os module attributes (stock vs new)"
diff <("$STOCK" -c "print('\n'.join(sorted(dir(__import__('os')))))") \
     <(eval $NEWRUN -c "print('\n'.join(sorted(dir(__import__('os')))))") \
  && echo "identical"

echo "== lib-dynload modules (stock vs new)"
diff <(ls "$(dirname "$(dirname "$(readlink -f "$STOCK")")")"/lib/python3.14/lib-dynload | sort) \
     <(ls "$PREFIX_DIR"/lib/python3.14/lib-dynload | sort) \
  && echo "identical"

echo "== builtin modules"
diff <("$STOCK" -c "print('\n'.join(sorted(__import__('sys').builtin_module_names)))") \
     <(eval $NEWRUN -c "print('\n'.join(sorted(__import__('sys').builtin_module_names)))") \
  && echo "identical"

echo "== key APIs"
eval $NEWRUN -c "import os; print({k: hasattr(os, k) for k in ['preadv','pwritev','setns','unshare','posix_spawn','posix_spawnp','chroot','setgid','initgroups']})"

echo "== multiprocessing / posixshmem"
eval $NEWRUN -c "
import multiprocessing as mp, _posixshmem
ctx = mp.get_context('fork')
with ctx.Pool(2) as p: print('pool', p.map(abs, [-1,-2,-3]))
"

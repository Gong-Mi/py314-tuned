#!/bin/sh
# Build CPython the way termux-packages builds it (same configure line, same
# patches, same feature set) and add the two things the distro build leaves on
# the table: computed gotos and a two-pass PGO trained on real interpreter /
# debugging workloads. Optionally packages the result as a .deb in an isolated
# prefix, so the system python is never touched.
#
# Usage:
#   ./build.sh                        # build + train (both sets) + package
#   ./build.sh --train normal         # only the interpreter/stdlib workloads
#   ./build.sh --train debug          # only the debugging workloads
#   ./build.sh --prefix "$HOME/opt/py" --jobs 2
#   ./build.sh --no-package           # just install into the prefix
#
# Tested on Termux/aarch64 (clang 24). Requires: clang, make, llvm-ar,
# llvm-ranlib, llvm-profdata, llvm-strip, curl, patch, dpkg-deb, zip.
set -eu

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
PY_VER=${PY_VER:-3.14.6}
WORK=${WORK:-$REPO_DIR/work}
TRAIN=${TRAIN:-both}
JOBS=${JOBS:-2}
PREFIX_DIR=${PREFIX_DIR:-$PREFIX/opt/py314tuned}
PKG_NAME=${PKG_NAME:-py314tuned}
DO_PACKAGE=1
PREPARE_ONLY=0
SYSTEM=0
INSTR_ONLY=0
PROFILE_DIR=${PROFILE_DIR:-}

while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK=$2; shift 2 ;;
    --prefix) PREFIX_DIR=$2; shift 2 ;;
    --train) TRAIN=$2; shift 2 ;;
    --jobs) JOBS=$2; shift 2 ;;
    --version) PY_VER=$2; shift 2 ;;
    --name) PKG_NAME=$2; shift 2 ;;
    --no-package) DO_PACKAGE=0; shift ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --system) SYSTEM=1; PREFIX_DIR=$PREFIX; PKG_NAME=python; shift ;;
    --instrument-only) INSTR_ONLY=1; SYSTEM=1; PREFIX_DIR=$PREFIX; PKG_NAME=python; shift ;;
    --profile-dir) PROFILE_DIR=$2; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

: "${PREFIX:?run inside Termux (PREFIX must be set)}"
SRC_DIR=$WORK/Python-$PY_VER
BUILD1=$WORK/build-instr
BUILD2=$WORK/build-final
STAGE_INSTR=$WORK/stage-instr
PROF=$WORK/pgo-profile
LOG=$WORK/build.log
DIST=$REPO_DIR/dist

mkdir -p "$WORK" "$DIST"
rm -rf "$BUILD1" "$BUILD2"   # stale configure caches from a previous prefix/flags

export CC=${CC:-clang}
export CXX=${CXX:-clang++}
export AR=${AR:-llvm-ar}
export RANLIB=${RANLIB:-llvm-ranlib}
export CPPFLAGS="-isystem$PREFIX/include/c++/v1 -isystem$PREFIX/include -DHAVE_PROCESS_VM_READV=1"
BASE_CFLAGS="-fstack-protector-strong -O3"

log() { echo "[$(date +%H:%M:%S)] $*"; }

fetch_source() {
  [ -d "$SRC_DIR" ] && { log "source already at $SRC_DIR"; return; }
  log "downloading Python-$PY_VER"
  curl -fL --retry 3 -o "$WORK/Python-$PY_VER.tar.xz" \
    "https://www.python.org/ftp/python/$PY_VER/Python-$PY_VER.tar.xz"
  tar -C "$WORK" -xf "$WORK/Python-$PY_VER.tar.xz"
}

fetch_patches() {
  local dest=$WORK/patches
  if [ -d "$dest" ] && [ -s "$dest/0010-enable-blocked-functions.patch" ]; then
    log "patches already at $dest"
    sed "s|@TERMUX_PREFIX@|$PREFIX|g" "$dest/0005-impl-multiprocessing.patch" > "$dest/0005-resolved.patch" 2>/dev/null || true
    return
  fi
  mkdir -p "$dest"
  log "downloading termux-packages python patches"
  # raw.githubusercontent sometimes answers 200 with a truncated body; retry on
  # size, not just on HTTP status.
  fetch_one() {
    _f=$1
    _out=$dest/$_f
    _i=0
    while [ "$_i" -lt 6 ]; do
      curl -sfL --max-time 60 -o "$_out" \
        "https://raw.githubusercontent.com/termux/termux-packages/master/packages/python/$_f" || true
      if [ -s "$_out" ] && [ "$(wc -c < "$_out")" -gt 100 ]; then return 0; fi
      _i=$((_i + 1)); sleep 2
    done
    return 1
  }
  _missing=""
  for f in 0001-fix-hardcoded-paths.patch 0002-no-setuid-servers.patch \
           0003-ctypes-util-use-llvm-tools.patch 0004-impl-getprotobyname.patch \
           0005-impl-multiprocessing.patch 0006-disable-multiarch.patch \
           0007-fix-ctypes-util-find_library.patch 0008-do-not-hardlink.patch \
           0009-fix-module-linking.patch 0010-enable-blocked-functions.patch; do
    if fetch_one "$f"; then log "fetched $f"; else
      case "$f" in
        0009-*) log "warn: $f unavailable (optional)" ;;
        *) _missing="$_missing $f" ;;
      esac
    fi
  done
  [ -n "$_missing" ] && { log "ERROR missing required patches:$_missing"; exit 1; }
  sed "s|@TERMUX_PREFIX@|$PREFIX|g" "$dest/0005-impl-multiprocessing.patch" > "$dest/0005-resolved.patch"
}

apply_patches() {
  cd "$SRC_DIR"
  if grep -q 'static int shm_open' Modules/_multiprocessing/posixshmem.c 2>/dev/null; then
    log "patches already applied in $SRC_DIR"
    return
  fi
  log "applying termux patches (context drift on configure hunks is expected)"
  for p in "$WORK"/patches/000*.patch; do
    case "$p" in *0005-impl-multiprocessing.patch|*0005-resolved.patch|*0010-enable-blocked-functions.patch) continue ;; esac
    patch -p1 --forward --no-backup-if-mismatch < "$p" >/dev/null 2>&1 \
      && log "applied $(basename "$p")" || log "skipped $(basename "$p") (context drift)"
  done
  patch -p1 --forward --no-backup-if-mismatch < "$WORK/patches/0005-resolved.patch" >/dev/null 2>&1 \
    && log "applied 0005 (shm_open/shm_unlink implementation)" || log "skipped 0005"
  # 0010: C hunks apply on 3.14.6, its configure hunks never do (handled below).
  patch -p1 --forward --no-backup-if-mismatch < "$WORK/patches/0010-enable-blocked-functions.patch" >/dev/null 2>&1 \
    && log "applied 0010 (posixmodule/socketmodule guards)" || log "skipped 0010"

  # The configure hunks of 0010/0005 only remove CPython's Android denylist;
  # do it textually so the result does not depend on patch line numbers.
  python3 - "$SRC_DIR" <<'PY'
import sys, pathlib
src = pathlib.Path(sys.argv[1])
blocks = [
'''  # When these functions are used in an unprivileged process, they crash rather
  # than returning an error.
  blocked_funcs="chroot initgroups setegid seteuid setgid sethostname
    setregid setresgid setresuid setreuid setuid"

''',
'''  # These functions are unimplemented and always return an error
  # (https://android.googlesource.com/platform/system/sepolicy/+/refs/heads/android13-release/public/domain.te#1044)
  blocked_funcs="$blocked_funcs sem_open sem_unlink"

''']
for name in ("configure", "configure.ac"):
    p = src / name
    s = p.read_text()
    for b in blocks:
        s = s.replace(b, '  blocked_funcs=""\n\n' if 'sem_open' in b else '')
    p.write_text(s)
print("blocked_funcs denylist removed")
PY
  rm -f "$SRC_DIR"/configure.rej "$SRC_DIR"/configure.ac.rej
  # 0010's configure hunk can fail on version drift while its C hunks still
  # apply; make sure the C side landed and fail loudly otherwise.
  grep -q 'static int shm_open' "$SRC_DIR/Modules/_multiprocessing/posixshmem.c" \
    || { log "ERROR 0005 shm implementation missing"; exit 1; }
  grep -q 'getuid() != 0' "$SRC_DIR/Modules/posixmodule.c" \
    || { log "ERROR 0010 posixmodule guards missing"; exit 1; }
  if grep -q 'blocked_funcs="chroot' "$SRC_DIR/configure"; then
    log "ERROR configure denylist still present"; exit 1
  fi
}

pin_features() {
  # Align the compile-time feature set with the stock Termux package: its cross
  # build linked against API-24 stubs, we link against the device libc.
  local b=$1
  cd "$b"
  for m in HAVE_PREADV HAVE_PWRITEV HAVE_SETNS HAVE_UNSHARE \
           HAVE_SEM_OPEN HAVE_SEM_UNLINK HAVE_SEM_TIMEDWAIT HAVE_SEM_GETVALUE; do
    sed -i -e "s@/\* #undef $m \*/@#define $m 1@" ./pyconfig.h
    grep -q "^#define $m 1" ./pyconfig.h || echo "#define $m 1" >> ./pyconfig.h
  done
  sed -i -e '/^#define HAVE_POSIX_SPAWN 1$/d' -e '/^#define HAVE_POSIX_SPAWNP 1$/d' ./pyconfig.h
  sed -i -e 's@/\* #undef HAVE_COMPUTED_GOTOS \*/@#define HAVE_COMPUTED_GOTOS 1@' \
         -e 's@/\* #undef USE_COMPUTED_GOTOS \*/@#define USE_COMPUTED_GOTOS 1@' ./pyconfig.h
  log "pinned: $(grep -cE '^#define (HAVE_PREADV|HAVE_SETNS|USE_COMPUTED_GOTOS) 1' pyconfig.h)/3 key defines present"
}

configure_build() {  # $1=builddir $2=stage $3=extra cflags
  local build=$1 stage=$2 extra=$3
  export CFLAGS="$BASE_CFLAGS $extra"
  export LDFLAGS="-L$stage/lib -L$PREFIX/lib -Wl,-rpath=$stage/lib:$PREFIX/lib -Wl,--enable-new-dtags -Wl,-z,relro,-z,now -Wl,--no-as-needed,-landroid-support,--as-needed -landroid-posix-semaphore $extra"
  mkdir -p "$build"
  cd "$build"
  "$SRC_DIR/configure" \
    --disable-dependency-tracking \
    --prefix="$stage" --libdir="$stage/lib" --includedir="$stage/include" \
    --sbindir="$stage/bin" --libexecdir="$stage/libexec" \
    --disable-rpath --disable-rpath-hack --disable-nls \
    --with-system-ffi --with-system-expat --without-ensurepip \
    --enable-loadable-sqlite-extensions --enable-shared --enable-static \
    --host=aarch64-linux-android --build=x86_64-pc-linux-gnu \
    --with-build-python="$PREFIX/bin/python3.14" \
    ac_cv_file__dev_ptmx=yes ac_cv_file__dev_ptc=no \
    ac_cv_func_wcsftime=no ac_cv_func_ftime=no ac_cv_func_faccessat=no \
    ac_cv_func_link=no ac_cv_func_linkat=no ac_cv_buggy_getaddrinfo=no \
    ac_cv_little_endian_double=yes \
    ac_cv_posix_semaphores_enabled=yes ac_cv_func_sem_open=yes \
    ac_cv_func_sem_timedwait=yes ac_cv_func_sem_getvalue=yes ac_cv_func_sem_unlink=yes \
    ac_cv_func_shm_open=yes ac_cv_func_shm_unlink=yes ac_cv_working_tzset=yes \
    ac_cv_header_sys_xattr_h=no ac_cv_func_getgrent=yes \
    ac_cv_func_fexecve=no ac_cv_func_getlogin_r=no ac_cv_func_getloadavg=no \
    ac_cv_func_sem_clockwait=no ac_cv_func_preadv2=no ac_cv_func_pwritev2=no \
    ac_cv_func_close_range=no ac_cv_func_copy_file_range=no \
    ac_cv_func_pthread_getname_np=no ac_cv_func_lchmod=no \
    ac_cv_func_getentropy=no ac_cv_func_getpwent=no
  pin_features "$build"
}

train() {
  local py=$1
  export LD_LIBRARY_PATH="$(dirname "$(dirname "$py")")/lib"
  local profraw
  export LLVM_PROFILE_FILE="$PROF/py-%p.profraw"
  case "$TRAIN" in
    normal|both)
      log "training: interpreter microbenchmarks"
      "$py" "$REPO_DIR/scripts/bench_interp.py" >/dev/null ;;
  esac
  log "training: stdlib imports + compileall"
  "$py" "$REPO_DIR/scripts/train_extra.py"
  case "$TRAIN" in
    debug|both)
      log "training: debugging workloads"
      "$py" "$REPO_DIR/scripts/bench_debug.py" >/dev/null ;;
  esac
  unset LLVM_PROFILE_FILE
  log "merging profile"
  llvm-profdata merge -o "$PROF/py.profdata" "$PROF"/*.profraw
  llvm-profdata show --counts "$PROF/py.profdata" | head -3
}

package_system_deb() {
  local root=$WORK/sysroot
  # python-ensurepip-wheels owns ensurepip/_bundled; shipping it again makes
  # dpkg refuse the replacement ("trying to overwrite ...").
  rm -rf "$root$PREFIX/lib/python3.14/ensurepip/_bundled"
  local deb=$DIST/python_${PY_VER}-1+tuned1_aarch64.deb
  mkdir -p "$root/DEBIAN"
  local size_kb; size_kb=$(du -sk "$root$PREFIX" | cut -f1)
  cat > "$root/DEBIAN/control" <<EOF
Package: python
Version: ${PY_VER}-1+tuned1
Architecture: aarch64
Maintainer: Gong-Mi <local>
Installed-Size: $size_kb
Depends: gdbm, libandroid-posix-semaphore, libandroid-support, libbz2, libcrypt, libexpat, libffi, liblzma, libsqlite, ncurses, ncurses-ui-libs, openssl, readline, zlib, zstd
Provides: python3
Replaces: python
Section: devel
Priority: optional
Description: CPython ${PY_VER} (termux recipe config, computed gotos, PGO trained on $TRAIN workloads)
 Drop-in replacement for the distro python package: identical configure line and
 patches, faster interpreter core. Installs to the normal \$PREFIX paths.
EOF
  chmod 0755 "$root" "$root/DEBIAN"; chmod 0644 "$root/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$root" "$deb"
  log "system package: $deb ($(du -h "$deb" | cut -f1))"
  log "install:  dpkg -i $deb"
  log "rollback: pkg install --reinstall python"
}

package_instr_deb() {
  local root=$WORK/sysroot-instr
  local deb=$DIST/python_${PY_VER}-1+instr1_aarch64.deb
  mkdir -p "$root/DEBIAN"
  for f in py3compile py3clean; do
    [ -f "$PREFIX/bin/$f" ] && cp -a "$PREFIX/bin/$f" "$root$PREFIX/bin/$f" || true
  done
  [ -d "$PREFIX/lib/python3.14/debpython" ] && \
    cp -a "$PREFIX/lib/python3.14/debpython" "$root$PREFIX/lib/python3.14/" || true
  local size_kb; size_kb=$(du -sk "$root$PREFIX" | cut -f1)
  cat > "$root/DEBIAN/control" <<EOF
Package: python
Version: ${PY_VER}-1+instr1
Architecture: aarch64
Maintainer: Gong-Mi <local>
Installed-Size: $size_kb
Depends: gdbm, libandroid-posix-semaphore, libandroid-support, libbz2, libcrypt, libexpat, libffi, liblzma, libsqlite, ncurses, ncurses-ui-libs, openssl, readline, zlib, zstd
Provides: python3
Replaces: python
Section: devel
Priority: optional
Description: CPython ${PY_VER} instrumented (-fprofile-generate) for on-device PGO training
 Every python3 run writes a profraw into $PROF. Install, use the device
 normally, then finalise with --profile-dir.
EOF
  chmod 0755 "$root" "$root/DEBIAN"; chmod 0644 "$root/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$root" "$deb"
  log "instrumented package: $deb ($(du -h "$deb" | cut -f1))"
  log "install: dpkg -i $deb"
}

package_deb() {
  local root=$WORK/debroot
  rm -rf "$root"
  mkdir -p "$root/$(dirname "$PREFIX_DIR")" "$root$PREFIX/bin" "$root/DEBIAN"
  cp -a "$PREFIX_DIR" "$root$PREFIX_DIR"
  cat > "$root$PREFIX/bin/$PKG_NAME" <<WRAP
#!/bin/sh
# bionic ignores DT_RPATH/DT_RUNPATH: force the private libpython.
export LD_LIBRARY_PATH="$PREFIX_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$PREFIX_DIR/bin/python3.14" "\$@"
WRAP
  chmod 0755 "$root$PREFIX/bin/$PKG_NAME"
  local size_kb; size_kb=$(du -sk "$PREFIX_DIR" | cut -f1)
  cat > "$root/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $PY_VER-1
Architecture: aarch64
Maintainer: Gong-Mi <local>
Installed-Size: $size_kb
Depends: gdbm, libandroid-posix-semaphore, libandroid-support, libbz2, libcrypt, libexpat, libffi, liblzma, libsqlite, ncurses, ncurses-ui-libs, openssl, readline, zlib, zstd
Section: devel
Priority: optional
Description: CPython $PY_VER (termux recipe config, computed gotos, PGO trained on $TRAIN workloads)
 Isolated build under $PREFIX_DIR, invoked via $PREFIX/bin/$PKG_NAME.
EOF
  chmod 0755 "$root" "$root/DEBIAN"; chmod 0644 "$root/DEBIAN/control"
  local deb=$DIST/${PKG_NAME}_${PY_VER}-1_aarch64.deb
  dpkg-deb --build --root-owner-group "$root" "$deb"
  log "package: $deb ($(du -h "$deb" | cut -f1))"
}

{
  log "python $PY_VER -> $PREFIX_DIR  (train=$TRAIN, jobs=$JOBS, clang=$(clang --version | head -1))"
  fetch_source
  fetch_patches
  apply_patches
  [ "$PREPARE_ONLY" = 1 ] && { log "prepared source at $SRC_DIR"; exit 0; }

  if [ -n "$PROFILE_DIR" ]; then
    log "using existing profiles from $PROFILE_DIR"
    mkdir -p "$PROF"
    cp "$PROFILE_DIR"/*.profraw "$PROF"/ 2>/dev/null || true
    ls "$PROF"/*.profraw >/dev/null 2>&1 || { log "ERROR no .profraw in $PROFILE_DIR"; exit 1; }
    llvm-profdata merge -o "$PROF/py.profdata" "$PROF"/*.profraw
  else
    if [ "$INSTR_ONLY" = 1 ]; then
      # Instrumented build destined for the system prefix, so every `python3`
      # run on the device contributes to the profile.
      log "pass 1: instrumented build for the system prefix"
      configure_build "$BUILD1" "$PREFIX" "-fprofile-generate=$PROF"
      make -j"$JOBS"
      rm -rf "$WORK/sysroot-instr"; mkdir -p "$WORK/sysroot-instr"
      make install DESTDIR="$WORK/sysroot-instr"
      rm -rf "$WORK/sysroot-instr$PREFIX/lib/python3.14/ensurepip/_bundled"
      package_instr_deb
      log "profile directory: $PROF (written automatically by the instrumented build)"
      log "finalise later with: ./build.sh --system --profile-dir $PROF"
      exit 0
    fi

    log "pass 1: instrumented build"
    configure_build "$BUILD1" "$STAGE_INSTR" "-fprofile-generate=$PROF"
    make -j"$JOBS"
    make install

    log "training"
    rm -f "$PROF"/*.profraw
    train "$STAGE_INSTR/bin/python3.14"
  fi

  log "pass 2: profile-use build"
  configure_build "$BUILD2" "$PREFIX_DIR" "-fprofile-use=$PROF/py.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date"
  make -j"$JOBS"
  if [ "$SYSTEM" = 1 ]; then
    rm -rf "$WORK/sysroot"; mkdir -p "$WORK/sysroot"
    make install DESTDIR="$WORK/sysroot"
  else
    make install
  fi

  if [ "$SYSTEM" = 1 ]; then TREE="$WORK/sysroot$PREFIX"; else TREE="$PREFIX_DIR"; fi

  log "stripping (as the official package does)"
  find "$TREE" -name '*.so' -type f -exec llvm-strip --strip-unneeded {} + 2>/dev/null || true
  llvm-strip --strip-unneeded "$TREE/bin/python3.14" 2>/dev/null || true

  if [ "$SYSTEM" = 1 ]; then
    # keep the distro's byte-compilation helpers: dpkg triggers call them and
    # they are not part of the CPython build itself.
    for f in py3compile py3clean; do
      [ -f "$PREFIX/bin/$f" ] && cp -a "$PREFIX/bin/$f" "$TREE/bin/$f" || true
    done
    [ -d "$PREFIX/lib/python3.14/debpython" ] && \
      cp -a "$PREFIX/lib/python3.14/debpython" "$TREE/lib/python3.14/" || true
    package_system_deb
  else
    cat > "$PREFIX/bin/$PKG_NAME" <<WRAP
#!/bin/sh
export LD_LIBRARY_PATH="$PREFIX_DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
exec "$PREFIX_DIR/bin/python3.14" "\$@"
WRAP
    chmod 0755 "$PREFIX/bin/$PKG_NAME"
    [ "$DO_PACKAGE" = 1 ] && package_deb || true
    log "done. run: $PREFIX/bin/$PKG_NAME -VV"
  fi
} 2>&1 | tee -a "$LOG"

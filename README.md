# py314-tuned

在 Termux/aarch64 上，用 **termux-packages 官方同一套配置**（configure 行 + 补丁集）重建 CPython 3.14，
只加两个官方发布版没用的优化：**computed gotos** 和 **两遍 PGO**，训练集覆盖普通负载与调试负载。
产物装进独立 prefix，不碰系统 python，可选打成 `.deb`。

实测（本机 8 核但只允许 CPU7，6 轮交替 A/B，min 口径，stock=1.0）：

| 负载 | 相对 stock |
|---|---|
| fib（递归调用） | 0.878 |
| sort | 0.877 |
| json | 0.882 |
| str | 0.909 |
| dict | 0.918 |
| regex | 0.917 |
| int_loop | 0.922 |
| exception | 0.925 |
| float_loop | 1.009 |
| sha256（C 库） | 0.996 |
| class_call | 1.014 |
| **调试：pdb 单步** | **0.765** |
| **调试：traceback 格式化** | **0.817** |
| **调试：compile+dis** | **0.809** |
| **调试：logging exc_info** | **0.826** |
| **调试：inspect 栈帧** | **0.866** |
| **调试：settrace 逐行** | **0.876** |

结论：换编译器本身没有收益（同一套 flags 下 clang 24 相对 NDK clang 21 是持平到慢 10%），
收益全部来自 computed gotos + PGO；调试训练额外再拿 2~5%。

## 为什么这样做

1. **配置必须照官方**：`packages/python/build.sh` 的 configure 行，加上 `packages/python/` 的补丁集。
   补丁不是可选项，它们决定功能：
   - `0010-enable-blocked-functions.patch`：CPython 的 configure 在 `Linux-android` 分支会把
     `chroot initgroups setegid seteuid setgid sethostname setregid setresgid setresuid setreuid setuid`
     强制置 no；官方把它删掉并在 posixmodule/socketmodule 里改成 `getuid()!=0 → EPERM`。
   - `0005-impl-multiprocessing.patch`：同一分支还会把 `sem_open sem_unlink` 置 no，并在
     `Modules/_multiprocessing/posixshmem.c` 里自带 `shm_open`/`shm_unlink` 实现（落到 `$PREFIX/tmp/`），
     同时把 `Lib/multiprocessing/heap.py` 的 `/dev/shm` 候选清空。少了它 `_posixshmem` 会在
     dlopen 时找不到 `shm_open`，`multiprocessing.Pool` 直接挂。
2. **feature 探测要钉住**：官方是交叉编译，链接 API-24 stub，`os.posix_spawn` 等探测为 no；
   本机构建链接设备 API-36 libc，探测结果会偏。脚本在 configure 之后把 `HAVE_PREADV/PWRITEV/SETNS/UNSHARE/SEM_*`
   钉为 yes、`HAVE_POSIX_SPAWN/SPAWNP` 删掉，与官方包对齐。
3. **computed gotos**：官方交叉编译时 label-address 探测不通过（三份官方/本地 pyconfig 全是 undef），
   脚本在 pyconfig.h 里显式打开 `HAVE_COMPUTED_GOTOS` / `USE_COMPUTED_GOTOS`。
4. **PGO**：pass 1 用 `-fprofile-generate` 编一份插桩解释器 → 跑训练集 → `llvm-profdata merge`
   → pass 2 用 `-fprofile-use` 重编。训练集：
   - `scripts/bench_interp.py`：11 项解释器微基准（递归、整数/浮点循环、dict、sort、字符串、json、regex、sha256、方法调用、异常）
   - `scripts/train_extra.py`：20 个常用 stdlib 导入 + urlencode/json 往返 + `compileall` 400 个标准库文件
   - `scripts/bench_debug.py`：7 项调试负载（settrace 逐行、traceback 格式化、pdb 单步、cProfile+pstats、
     inspect 栈帧、logging exc_info、compile+dis）

## 用法

```sh
# 全量：官方配置 + computed gotos + PGO(普通+调试) + 打 deb
./build.sh

# 只跑正常负载训练 / 只跑调试训练
./build.sh --train normal
./build.sh --train debug

# 自定义前缀与并行度
./build.sh --prefix "$HOME/opt/py314tuned" --jobs 2

# 只准备源码和补丁（用于检查 patch 是否套得上）
./build.sh --prepare-only

# 装完直接跑
"$PREFIX/bin/py314tuned" -VV
```

产物与日志在 `work/`，deb 在 `dist/`。功能面核对：`./verify_parity.sh [prefix]`。

依赖：`clang make llvm-ar llvm-ranlib llvm-profdata llvm-strip curl patch dpkg-deb`
（Termux 上 `pkg install clang make llvm binutils curl patch dpkg`，其中 llvm 提供 llvm-* 工具）。

## 注意事项

- **必须走 wrapper**：bionic 的 linker 直接忽略 `DT_RPATH`/`DT_RUNPATH`
  （实测 `unused DT entry ... (ignoring)`），不设 `LD_LIBRARY_PATH` 时会去加载
  `$PREFIX/lib/libpython3.14.so`，静默变成系统 python 的内核。脚本会生成
  `$PREFIX/bin/<name>` 包装器。
- **不要把它拷进 `$PREFIX/bin` 覆盖系统 python**：那些路径归 dpkg 管，`pkg upgrade` 会覆盖，
  而且 libpython 同 soname，一覆盖全系统进程跟着变。
- PGO profile 与“源码 + flags”绑定，换版本或改 flags 必须重训。
- 官方包把 `test/`、`tkinter` 拆成子包；这里全部内置，所以体积更大（安装后约 290MB，deb 约 34MB）。
- 与你环境相关的两个小差异：本构建会多出 `os.ctermid` 和 `_uuid`（都是"多"不是"少"）。

## 参考

- termux-packages: `packages/python/build.sh`、`packages/python/*.patch`
- CPython: `configure.ac` 的 `Linux-android` 分支、`Modules/_multiprocessing/posixshmem.c`
- Android: bionic 忽略 RPATH/RUNPATH；API-24 stub 与设备 libc 的探测差异

## 替换官方 python（系统级）

```sh
./build.sh --system --train both        # 产出 dist/python_3.14.6-1+tuned1_aarch64.deb
dpkg -i dist/python_3.14.6-1+tuned1_aarch64.deb
python3 -VV                             # 应显示 Clang 24 + main Oct 24 2026
```

- 包名仍是 `python`，版本 `3.14.6-1+tuned1`（高于官方 `3.14.6-1`），`Provides: python3`。
  安装后 `python3`、`pip`、所有 site-packages 扩展继续可用；`_multiprocessing`/Pool 实测正常。
- 打包时会剔除 `ensurepip/_bundled`（归 `python-ensurepip-wheels` 所有，否则 dpkg 拒绝覆盖），
  并保留 `py3compile`/`py3clean`/`debpython`（dpkg 触发器要用）。
- **回滚**：`pkg install --reinstall python`（或 `pkg upgrade python`，官方版本号更高时会覆盖回来）。
- 风险：这会成为系统的 python，Hermes/MCP/脚本都用它；升级官方 python 会覆盖本包。

## 用真实负载训练（实机）

PGO 支持两段式：先装插桩版跑真实负载，再用收集到的 profile 出正式版。

```sh
# 1) 插桩版（会提示 profile 目录）
./build.sh --system --instrument-only
#    按提示导出环境变量，例如写进 ~/.bashrc：
#    export LLVM_PROFILE_FILE=$HOME/py314-tuned/work/pgo-profile/py-%p.profraw
# 2) 正常使用一段时间（MCP、脚本、pytest……每个进程都会落一个 .profraw）
# 3) 用收集到的 profile 出正式版
./build.sh --system --profile-dir "$HOME/py314-tuned/work/pgo-profile"
```

注意：插桩版比正式版慢 2~3 倍，训练完务必换回正式版；`*.profraw` 越多合并越慢，
可以只保留有代表性的那批。

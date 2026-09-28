# wtool-bootstrap

wtool 集合的**引擎**：一份代码，管理任意多个项目仓库的软链与 shell 注入。

```sh
# 日常三条（一条铁律：要 sudo 的都叫 sudo-*）
./wtool.sh sudo-install <项目>    # 系统层：/etc 下的文件、apt 包、要跑的脚本（可能要 sudo）
./wtool.sh install      <项目>    # 用户层：output/ → ~/.wtool，再铺 $HOME 软链（永不 sudo）
./wtool.sh uninstall    <项目>    # 撤销 install（不还原 /etc —— 那是 sudo-uninstall 的事）

# 系统层
./wtool.sh sudo-uninstall <项目>|all   # /etc 还原 + 卸掉这次装进来的 apt 包
./wtool.sh sudo-bootstrap              # 所有项目的 sudo-install

# 产物与发布（release 四条边：pack/unpack 本地一对，publish/download 远端一对）
./wtool.sh build          <项目>|all   # 跑项目自己的 scripts/build.sh → output/
./wtool.sh pack-release   <项目>       # output/ → release/（源码.zip / release.zip / 分卷 / dist.json）
./wtool.sh publish-release [<项目>]    # release/ → GitHub（**只上传**），成功后写 scripts/release.json
./wtool.sh download-release <项目>|all # 读提交在项目里的 scripts/release.json → release/（**只下载**）
./wtool.sh unpack-release <项目>       # 照 dist.json 校验分卷 → 拼接 → 解到 output/

# 层（第二条通道：容器镜像仓库；layer/ 是一棵 OCI 镜像布局，ADR-024）
./wtool.sh layer-save   <项目> --image=<镜像>   # docker 镜像 → layer/<target>/
./wtool.sh layer-load   <项目>                  # layer/<target>/ → docker
./wtool.sh unpack-layer <项目> [--layer=<层>]   # layer/ 顶层 blob → output/（不联网、不要 docker）
./wtool.sh push-layer   <项目>                  # layer/ → 镜像仓库（docker push，构建机上跑）
./wtool.sh pull-layer   <项目>                  # 镜像仓库 → layer/（目标机只要 skopeo，不要 docker）

# 一次装好 / 出问题
./wtool.sh bootstrap                  # 所有项目 install（不做系统层、不联网）
./wtool.sh check|repair [<项目>]      # 声明/日志/磁盘三者对比；只重建不删除
./wtool.sh status | doctor | validate | init | kill-self-forever
./tests/run_all.sh                    # 8 组 / 431 条断言
                                      # pairing 35 / sudo-install 24 / publish 114 / table 43
                                      # release-copy 17 / release 62 / contract 97 / layer 39
```

---

## 设计一句话

> **bootstrap 是引擎（一份），项目是数据（各一份）；Python 只算不写，Shell 只写不算；状态目录既是日志也是注册表；"完全配对"由测试证明而不是由约定保证。**

## 目录

| 路径 | 作用 |
|---|---|
| `wtool.sh` | CLI 入口 |
| `lib/wtool_plan.py` | 规划器：解析 `wtool.xml`、校验、算 rc 新内容、算发布文件表（只写 scratch） |
| `lib/wtool_fs.sh` | 执行器：软链、原子写、journal、registry、打包/解包（**受管**写入都走这里） |
| `lib/wtool_zip.py` | 打包工具：zip 的读写（中文名要 UTF-8 标志，系统的 zip 不设） |
| `tests/` | 7 组断言：pairing / sudo-install / publish / table / release-copy / release / contract |
| `docs/spec.md` | **接口契约**（改代码前先看） |
| `docs/manifest-schema.md` | `wtool.xml` 完整字段表 |
| `docs/roadmap.md` | 只剩一个指针 —— 内容已并入 `harness/BACKLOG.md` |
| `templates/*.tpl` | 项目脚本模板（`wtool init --with-build` / `--with-install` 用；只有这两种） |
| `lib/wtool_os.sh` | 系统探测 + sudo 层（`/etc`、apt、任务） |

## 环境变量

引擎自身用的（可覆盖）：

| 变量 | 默认 | 说明 |
|---|---|---|
| `WTOOL_HOME` | `$HOME` | 被管理的家目录（测试用） |
| `WTOOL_STATE` | `$XDG_STATE_HOME/wtool` 或 `~/.local/state/wtool` | 状态目录 |
| `WTOOL_ROOT` | bootstrap 的上级目录 | 推断项目默认 id |
| `WTOOL_BOOTSTRAP` | 存根自动查找 | 显式指定引擎位置 |

bootstrap 项目（自举）提供的**长期变量**，重启 shell 后依然可用：

| 变量 | 值 |
|---|---|
| `WTOOL_PREFIX` | `$HOME/.wtool/usr`（编译安装前缀） |
| `WTOOL_OS_ID` / `WTOOL_OS_VERSION` / `WTOOL_OS_CODENAME` / `WTOOL_OS_LIKE` | 从 `/etc/os-release` 探测 |
| `WTOOL_ARCH` / `WTOOL_JOBS` | `uname -m` / `nproc` |
| `PATH` | 追加 `$WTOOL_PREFIX/bin` 与 `$WTOOL_PROJECT_DIR/bin`（`wtool` 命令） |

**项目脚本拿到的变量**（`wtool.sh:325-335`，只在跑 `scripts/*.sh` 期间有效）：

```
WTOOL_PROJECT_ID / WTOOL_PROJECT_DIR / WTOOL_PROJECT_ROOT / WTOOL_WORKSPACE /
WTOOL_HOME / WTOOL_PREFIX / WTOOL_JOBS / WTOOL_ARCH / WTOOL_OS_* /
WTOOL_ARTIFACTS / WTOOL_STATE_DIR
```

`<source>` 任务另外拿得到 `WTOOL_SOURCE_DIR` / `WTOOL_SOURCE_REF`（`lib/wtool_fs.sh:555-557`）。
完整契约见 `docs/spec.md` §10。

> ⚠️ 旧文档里写的 `WTOOL_SRC_DIR` / `WTOOL_REF` **不存在**（全仓 grep 零命中），别照那个写脚本。

## 自举

`bootstrap` 本身也是一个 wtool 项目：

```sh
cd bootstrap && ./install.sh     # 建 ~/.wtool/wtool-work-dir/links/bootstrap + 写 rc 块
exec zsh                          # 之后 wtool / WTOOL_PREFIX / OS 变量就位
wtool doctor
```

## 依赖

- `sh`（POSIX）、`python3`（3.6+，只用标准库）、`git`
- 不用 PyYAML / 不用 TOML：清单是 XML，解析走 `xml.etree`

**构建方式写在清单里**（`<build kind="local|docker"/>`，ADR-025）：引擎因此能在动手之前
判断这台机器行不行 —— `kind="docker"` 而没有 docker 时 `wtool build` 直接拒绝并指路
`download-release`（退出码非 0），kind 还决定 `output/` 有没有 `<os>_<ver>/` 那一层。
`WTOOL_DOCKER=<路径>` 可以指定 docker 二进制。

## 当前状态

引擎 `1.0.0`，schema `1`。

**已实现**：`install` / `uninstall` / `sudo-install` / `sudo-uninstall` / `sudo-bootstrap` /
`bootstrap` / `build` / `pack-release` / `publish-release` / `download-release` / `unpack-release` /
`layer-save` / `layer-load` / `unpack-layer` / `push-layer` / `pull-layer` /
`check` / `repair` / `status` / `doctor` / `validate` / `init` / `kill-self-forever` /
`version`，加 `--dry-run` / `--force`。另外有三个**帮助里没写**的隐藏入口：
`wtool docs` / `wtool docs refresh` / `wtool refresh-downloads`
（同一个实现，重刷文档里的下载链接）。

**已经删掉的命令**（都会给出"现在该用什么"）：

| 删掉的 | 现在用什么 |
|---|---|
| `download` | `download-release` + `unpack-release`（**语义变了**：只下到 `release/`，不解包） |
| `publish` | `pack-release` + `publish-release`（**语义变了**：只上传，不打包） |
| `provision` | `sudo-install`（`--with-system` 一并删掉） |
| `table` | 裸跑 `wtool` |
| `list` | `wtool status`（登记表并进去了） |
| `env` | `wtool doctor`（`doctor --quiet` 只输出 export 行） |
| `scaffold` | `wtool init <目录>`（**整个删掉**，不是改名） |
| `pack-layer` | 删了（**方向反了**，ADR-024）：层是源、`output/` 是层的导出物。现在 `layer-save`（镜像 → `layer/`）+ `unpack-layer`（`layer/` → `output/`） |
| `push-layers` / `pull-layers` | `push-layer` / `pull-layer`：推拉的是 `layer/<target>/` 里的**真镜像**，`pull-layer` 也不再直接落 `output/`（要多一步 `unpack-layer`） |

前两条**故意不留兼容窗口**（ADR-023）：名字一样、语义不一样，静默兼容会做出错误的事
（让人以为东西在 `output/` 里，其实在 `release/`）。

**项目脚本只剩两种**：`scripts/build.sh`（怎么编，产物进 `output/`）和
`scripts/install.sh`（怎么铺，`output/` → `~/.wtool/usr`）。
`download.sh` / `publish.sh` / `extract.sh` 全部退休 —— 下载和发布全项目走同一条引擎的路。
`wtool init --with-download` / `--with-publish` 同理取消（只剩 `--with-build` / `--with-install`）。
**"文件存在即能力声明"不变，但只有这两种**；项目表的能力列因此是 `build` / `install` 两列。

**`<publish>` 还在**：`kind="source"`（默认）/ `kind="none"`（不发布）/ `to="owner/repo"`
（推到别的仓）都仍然有效，`<sub>`（替没有 `wtool.xml` 的上游子树表态）和 `<target>`
（目标系统矩阵）也照旧解析。只有 **`kind="script"` 和 `script=` 取消了**：
写它们是清单错误，`wtool validate` 会拒绝并提示"发布不再调项目脚本，构建逻辑放
`scripts/build.sh`"。旧标签（`<env>` / `<link src= dest=>` / `<provision>` / `<system-file>`）
仍然认，但 `wtool validate` 和每次解析都会警告 —— 等项目都迁到新标签
（`<zshrc>` / `<bashrc>` / 三段 `<link>` / `<sudo-install>`）就删掉兼容分支。

**还没做**（见 `harness/BACKLOG.md`）：
`check --json`、`--prune`、`--exact`、并发锁、fish 支持。

**已实现但需要 root**：`/etc` 改动备份的**第二份** `/var/backups/wtool/<原始路径>`
（`lib/wtool_fs.sh:379-441`）—— 非 root 时跳过这一份并打印说明，
其余两份（原文件旁边 + state）照常写。

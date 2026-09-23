# wtool-bootstrap

wtool 集合的**引擎**：一份代码，管理任意多个项目仓库的软链与 shell 注入。

```sh
# 日常三条（一条铁律：要 sudo 的都叫 sudo-*）
./wtool.sh sudo-install <项目>    # 系统层：/etc 下的文件、apt 包、要跑的脚本（可能要 sudo）
./wtool.sh install      <项目>    # 用户层：release/ → ~/.wtool，再铺 $HOME 软链（永不 sudo）
./wtool.sh uninstall    <项目>    # 撤销 install（不还原 /etc —— 那是 sudo-uninstall 的事）

# 系统层
./wtool.sh sudo-uninstall <项目>|all   # /etc 还原 + 卸掉这次装进来的 apt 包
./wtool.sh sudo-bootstrap              # 所有项目的 sudo-install

# 产物与发布
./wtool.sh build|download <项目>|all   # 跑项目自己的 scripts/build.sh / download.sh
./wtool.sh pack-release   <项目>       # → <项目>/publish/（源码.zip / release.zip / 分卷 / dist.json）
./wtool.sh unpack-release <项目>       # 照 dist.json 校验分卷 → 拼接 → 解到 release/
./wtool.sh publish        [<项目>]     # pack-release + 上传（有 scripts/publish.sh 的走那个脚本）

# 一次装好 / 出问题
./wtool.sh bootstrap                  # 所有项目 install（不做系统层、不联网）
./wtool.sh check|repair [<项目>]      # 声明/日志/磁盘三者对比；只重建不删除
./wtool.sh status | doctor | validate | init | kill-self-forever
./tests/run_all.sh                    # 7 组 / 266 条断言
```

---

## 设计一句话

> **bootstrap 是引擎（一份），项目是数据（各一份）；Python 只算不写，Shell 只写不算；状态目录既是日志也是注册表；"完全配对"由测试证明而不是由约定保证。**

## 目录

| 路径 | 作用 |
|---|---|
| `wtool.sh` | CLI 入口 |
| `lib/wtool_plan.py` | 规划器：解析 `wtool.xml`、校验、算 rc 新内容、算发布文件表（只写 scratch） |
| `lib/wtool_fs.sh` | 执行器：软链、原子写、journal、registry、打包/解包（唯一写 `$HOME` 的地方） |
| `lib/wtool_zip.py` | 打包工具：zip 的读写（中文名要 UTF-8 标志，系统的 zip 不设） |
| `tests/` | 7 组断言：pairing / sudo-install / publish / table / release-copy / release / contract |
| `docs/spec.md` | **接口契约**（改代码前先看） |
| `docs/manifest-schema.md` | `wtool.xml` 完整字段表 |
| `docs/roadmap.md` | 未来方向与预留设计 |

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

**构建期专用变量**（`WTOOL_SRC_DIR` / `WTOOL_REF` 等）不进 shell，由引擎在跑 `wsw.sh` 前临时注入。
完整契约见 `docs/spec.md` §10。

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

## 当前状态

引擎 `1.0.0`，schema `1`。

**已实现**：`install` / `uninstall` / `sudo-install` / `sudo-uninstall` / `sudo-bootstrap` /
`bootstrap` / `build` / `download` / `pack-release` / `unpack-release` / `publish` /
`check` / `repair` / `status` / `doctor` / `validate` / `init` / `kill-self-forever` /
`version`，加 `--dry-run` / `--force`。

**已经删掉的命令**（都会给出"现在该用什么"）：

| 删掉的 | 现在用什么 |
|---|---|
| `provision` | `sudo-install`（`--with-system` 一并删掉） |
| `table` | 裸跑 `wtool` |
| `list` | `wtool status`（登记表并进去了） |
| `env` | `wtool doctor`（`doctor --quiet` 只输出 export 行） |

**已经删掉的标签**：`<publish>` / `<sub>` / `<target>`（能力由文件声明：有
`scripts/publish.sh` 就是脚本型发布）。旧标签（`<env>` / `<link src= dest=>` /
`<provision>` / `<system-file>` / `<publish>`）在**过渡期仍然认**，但 `wtool validate`
和每次解析都会警告 —— 等项目都迁到新标签（`<zshrc>` / `<bashrc>` / 三段 `<link>` /
`<sudo-install>`）就删掉兼容分支。

**还没做**（见 `harness/notes/00-architecture.md` 的 🚧 与 `docs/roadmap.md`）：
`/var/backups/wtool` 那一份备份需要 root（非 root 时跳过并说明）、
`check --json`、`publish` 的目标系统矩阵（`<target>` 随 `<publish>` 一起删了，
现在由项目自己的 `scripts/publish.sh` 决定）、`--prune`、`--exact`、并发锁、fish 支持。

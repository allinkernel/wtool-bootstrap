# wtool-bootstrap

wtool 集合的**引擎**：一份代码，管理任意多个项目仓库的软链与 shell 注入。

```sh
# 在任意项目目录下
./install.sh          # 建软链 + 往 ~/.zshrc 写受管块
./uninstall.sh        # 完全回退
```

或直接驱动引擎：

```sh
# 可逆部分（软链 + rc 块，不需要 root）
./wtool.sh install   ../terminal/tmux
./wtool.sh uninstall ../terminal/tmux

# 不可逆部分（换源 / 装包 / 编译，与 install 分离）
./wtool.sh provision ../os/ubuntu --with-system
./wtool.sh bootstrap                 # 全工作区按 priority 依次 provision + install

# 其它
./wtool.sh list | status | doctor | env | scaffold | validate
./tests/run_all.sh                   # 27 + 22 条断言
```

---

## 设计一句话

> **bootstrap 是引擎（一份），项目是数据（各一份）；Python 只算不写，Shell 只写不算；状态目录既是日志也是注册表；"完全配对"由测试证明而不是由约定保证。**

## 目录

| 路径 | 作用 |
|---|---|
| `wtool.sh` | CLI 入口 |
| `lib/wtool_plan.py` | 规划器：解析 `wtool.xml`、校验、计算 rc 新内容（只写 scratch） |
| `lib/wtool_fs.sh` | 执行器：软链、原子写、journal、registry（唯一写 `$HOME` 的地方） |
| `templates/stub.sh` | 项目存根模板（`install.sh`/`uninstall.sh` 都是它的副本） |
| `tests/pairing_test.sh` | 7 组场景 / 17 条断言，全在临时 `$HOME` 里跑 |
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
cd bootstrap && ./install.sh     # 建 ~/.wtool/links/bootstrap + 写 rc 块
exec zsh                          # 之后 wtool / WTOOL_PREFIX / OS 变量就位
wtool doctor
```

## 依赖

- `sh`（POSIX）、`python3`（3.6+，只用标准库）、`git`
- 不用 PyYAML / 不用 TOML：清单是 XML，解析走 `xml.etree`

## 当前状态

引擎 `1.0.0`，schema `1`。已实现 install / uninstall / list / status / doctor / scaffold / validate / `--dry-run` / `--force`，以及 bootstrap 自举（长期环境变量 + `wtool` 命令）。

已实现 `provision` 层：`<system-file>`（换源，含备份/还原）、`<source>`（wsw.sh 编译型项目）、
`<provision>`（Ansible / shell 任务，带幂等 marker）、`wtool bootstrap`。

**未实现**（见 `docs/roadmap.md`）：`--prune`、`--exact`、并发锁、fish 支持。

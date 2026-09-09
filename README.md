# wtool-bootstrap

wtool 集合的**引擎**：一份代码，管理任意多个项目仓库的软链与 shell 注入。

```sh
# 在任意项目目录下
./install.sh          # 建软链 + 往 ~/.zshrc 写受管块
./uninstall.sh        # 完全回退
```

或直接驱动引擎：

```sh
./wtool.sh install   ../terminal/tmux
./wtool.sh uninstall ../terminal/tmux
./wtool.sh list
./wtool.sh status
./wtool.sh doctor
./wtool.sh scaffold  ../new-project --id tools/new
./tests/pairing_test.sh
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

| 变量 | 默认 | 说明 |
|---|---|---|
| `WTOOL_HOME` | `$HOME` | 被管理的家目录（测试用） |
| `WTOOL_STATE` | `$XDG_STATE_HOME/wtool` 或 `~/.local/state/wtool` | 状态目录 |
| `WTOOL_ROOT` | bootstrap 的上级目录 | 推断项目默认 id |
| `WTOOL_BOOTSTRAP` | 存根自动查找 | 显式指定引擎位置 |

## 依赖

- `sh`（POSIX）、`python3`（3.6+，只用标准库）、`git`
- 不用 PyYAML / 不用 TOML：清单是 XML，解析走 `xml.etree`

## 当前状态

引擎 `1.0.0`，schema `1`。已实现 install / uninstall / list / status / doctor / scaffold / validate / `--dry-run` / `--force`。

**未实现**（见 `docs/roadmap.md`）：provision（apt/编译）、system scope（写 `/etc`）、`--prune`、`--exact`、并发锁。

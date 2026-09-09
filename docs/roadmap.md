# 路线图与预留设计

记录"想清楚了但还没写"的东西。写代码前先读 `docs/spec.md`。

---

## 1. provision：安装软件 / 编译（最紧迫）

**问题**：mytool 的 `os` 项目要 `sudo apt install`、`nvim` 项目要源码编译 neovim。这些操作**不可逆**，一旦混进 `install`，"完全配对"这条不变量就没了。

**设计**：清单新增 `<task>`，但**不归 install 管**：

```xml
<wtool schema="1" id="os/ubuntu" priority="5">
  <task src="provision/apt.sh"  when="os:ubuntu"  desc="安装基础软件包"/>
  <task src="provision/mirror.sh" when="os:ubuntu" desc="替换 apt 镜像源（写 /etc，不可逆）"/>
</wtool>
```

```sh
wtool.sh provision ../os/ubuntu          # 显式执行，不进 install
wtool.sh provision ../os/ubuntu --list   # 只看有哪些任务
```

规则：

| 规则 | 理由 |
|---|---|
| `provision` 是独立子命令，`install` 永不自动调用 | 保住可逆性 |
| 每个 task 必须**幂等**（重复执行安全） | 新机器重跑 |
| task 输出记入 `$WTOOL_STATE/<id>/provision.log` | 可审计 |
| 不可逆的 task 必须带 `when` 和 `desc` | 让人看清它在干什么 |
| task 失败 → 整条 provision 中止 | 避免半成品状态 |

**待定**：是否要"provision 过的版本"记进 registry，以便提示"这台机器还没 provision 过这个项目"。

---

## 2. system scope：写 `$HOME` 之外

`os` 项目要改 `/etc/apt/sources.list`。这既不可逆，又要 root。

```xml
<copy src="ustc/noble.sources.list" dest="/etc/apt/sources.list"
      scope="system" backup="true"/>
```

规则：

| 规则 | 理由 |
|---|---|
| `scope="system"` 必须显式写，默认 `home` | 防止误写系统文件 |
| 需要 `--allow-system`，否则拒绝 | 二次确认 |
| 写前自动备份 `dest.wtool-bak.<时间戳>` | 可人工恢复 |
| **不记入 journal**，只输出"如何手工撤销" | 假装可逆比不可逆更危险 |
| `dest` 必须是白名单前缀（`/etc`、`/usr/local`） | 防止 `dest="/"` 之类的灾难 |

---

## 3. `--prune`：install 时清掉"清单已删但磁盘还在"的软链

现状：从清单里删掉一个 `<link>` 后重装，旧软链还在（journal 里也还在），直到 uninstall 才清。

```
wtool.sh install <项目> --prune
```

语义：以 journal 为基准，凡"journal 里有、当前清单里没有"的软链 → 删除并记 journal。

---

## 4. `--exact`：用历史版本推导逆操作

现在 uninstall 靠 journal（"我做过什么"）。更严的做法：用块里记的 `head` 从 git 历史取出**当时的** `wtool.xml`，按当时的逻辑推导逆操作。

```sh
git cat-file -p <head>:wtool.xml
```

价值：即使引擎逻辑改过，也能精确配对。成本：需要仓库还在且历史完整。
优先级低——journal 已经覆盖了绝大多数情况。

---

## 5. 并发锁

两个终端同时 `install` 会撞 `registry.tsv` 和 `journal.tsv`。

```sh
flock "$WTOOL_STATE/.lock" wtool.sh install ...
```

或在 `wtool.sh` 里对所有写操作加 flock。优先级低（单人单机很少并发）。

---

## 6. `wtool` 命令本身

把 `wtool.sh` 软链成 `~/.local/bin/wtool`，支持：

```sh
wtool install <目录>      wtool list      wtool status
wtool doctor              wtool scaffold
```

前提：`~/.local/bin` 在 PATH 里。可以由某个项目的 `env` 负责（而不是在 install 里改 PATH）。

---

## 7. 多 shell

`shells="zsh,bash"` 已经能用。若要支持 fish / nu：

| shell | 注入方式 |
|---|---|
| zsh | `~/.zshrc` 块 |
| bash | `~/.bashrc` 块 |
| fish | `~/.config/fish/conf.d/<id>.fish`（conf.d 天然适合，不需要块） |
| nu | `~/.config/nushell/env.nu` 需要块 |

fish 的 conf.d 是个特例：**一个文件就是一次注入**，比块更干净，值得单独设计。

---

## 8. 已知取舍

| 取舍 | 现状 | 备注 |
|---|---|---|
| 两级软链（中转 + 项目内） | 已采用 | 换来"仓库可搬家"；代价是 `readlink` 多一跳 |
| TSV 而非 JSON 作为 py↔sh 接口 | 已采用 | 路径含制表符才会出问题，可接受 |
| `id` 写死在 `~/.wtool/links/<id>` | 已采用 | 改 id = 重装，写进文档 |
| 清单用 XML 而非 TOML | 已采用 | 为了在**全新机器**上不依赖 Python 3.11+ 的 `tomllib` |
| 块里不放时间戳 | 已采用 | 实测：放了会破坏幂等 |
| journal 按 `(action,dest)` 去重 | 已采用 | 实测：不去重会导致重复 install 后卸载不干净 |

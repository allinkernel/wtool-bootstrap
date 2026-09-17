# wtool 接口契约（spec v1.0.0）

> 本文是 `wtool-bootstrap` 与各项目仓库之间的**唯一契约**。
> 改引擎前先改这里；改这里就要考虑向后兼容。

---

## 1. 目标与不变量

| 目标 | 检验方式 |
|---|---|
| **零侵入** | install 只在 `$HOME` 下创建软链和"受管块"；不覆盖任何已有文件（除非 `--force`，且先备份） |
| **完全配对** | install 之后 uninstall，`$HOME` 必须字节级回到 install 之前 |
| **幂等** | 连续多次 install，结果与一次 install 完全相同（包括 rc 文件内容） |
| **顺序无关** | 多个项目以任意顺序安装，`~/.zshrc` 的最终内容一致 |
| **可迁移** | 仓库搬到任意路径，rc 块一个字都不用改（靠 `~/.wtool/links/<id>` 中转） |
| **可撤销且可审计** | 撤销依据是 journal（"我做过什么"），不是"重新推导" |

四条不变量：

1. **仓外的一切改动，要么是软链，要么是受管块。** 没有第三种形态。
2. **每个动作都记进 journal。** uninstall 是逆序重放，不是重新计算。
3. **Python 只算不写。** 除 scratch 目录外，py 不产生任何副作用。
4. **Shell 只写不算。** 所有落盘动作集中在 `lib/wtool_fs.sh`，文本逻辑全在 py。

### 两个角色：声明链接 vs 稳定地址

很多疑问都源于把这两者混为一谈：

| 角色 | 谁创建 | 在清单里声明吗 | 用途 | 例子 |
|---|---|---|---|---|
| **声明链接** | `<link>` | ✅ | "应用去这个位置找配置" | `~/.tmux.conf` |
| **稳定地址** | 引擎 install 时自动 | ❌ | "整个项目的稳定、防搬家路径"，供**配置内部互相引用** | `~/.wtool/links/<id>`（指向项目根） |

**规则**：
- 清单只声明"应用去找的"链接；
- 配置文件**内部**要引用本项目其它文件时，写 `$HOME/.wtool/links/<id>/...`（稳定地址），不要写仓库真实路径，也不要用 `$HOME` 之外的 env 变量（见下）。
- 为什么不能只靠 env 变量（如 `WTOOL_TMUX_DIR`）：tmux 的 `#()` 命令在**渲染时**用 `sh -c` 执行，`$HOME` 必然存在；而自定义 env 变量只有"启动 tmux server 的那个 shell 里 source 过它"才在。**`$HOME/.wtool/links/<id>` 是唯一两者兼得的选择**（实测 tmux 3.4 验证）。

> 代价：`id` 因此成了**对外契约**，会同时出现在 `~/.wtool/links/<id>`、rc 块、和配置文件的引用里。改 id = 改三处 + 重装。已写进本规范与 `terminal/tmux/wtool.xml` 的注释。

---

## 2. 角色划分

```
wtool-bootstrap/            引擎（全机器唯一一份）
├── wtool.sh                CLI：install / uninstall / list / status / doctor / scaffold / validate
├── lib/wtool_plan.py       规划器：解析清单、校验、算 rc 新内容（只写 scratch）
├── lib/wtool_fs.sh         执行器：软链、原子写、journal、registry（唯一写 $HOME 的地方）
├── templates/stub.sh       项目存根模板（install.sh / uninstall.sh 都是它的副本）
└── tests/pairing_test.sh   自测：把上面 6 个目标变成可执行的断言

<项目>/                      数据（每个仓库一份）
├── wtool.xml               声明：env 归属、链接表、优先级
├── env.zsh / env.sh       被 source 的部分（无副作用）
├── install.sh              存根：找到 bootstrap 并 exec
└── uninstall.sh            存根：同上
```

状态（不在仓库里，属于这台机器）：

```
$WTOOL_STATE/                       默认 ~/.local/state/wtool
├── registry.tsv                    dest -> 项目id（全局视图，用于跨项目冲突检测）
└── <project-id>/
    ├── meta.tsv                    版本/来源/时间等溯源信息
    └── journal.tsv                 这个项目做过什么（撤销的唯一依据）
```

---

## 3. 数据流

```
install <项目>
  │
  ├─ sh: 前置检查（git 干净？拿到 HEAD）
  │
  ├─ py plan-install ──► scratch/plan.tsv     动作表
  │                     scratch/meta.tsv      project_id 等
  │                     scratch/rc.<n>         rc 文件的最终内容
  │
  └─ sh: 逐行执行 plan.tsv
           reg  → 只更新 registry
           link → 建软链 + 记 journal
           rc   → 原子替换（跟随软链）+ 记 journal
```

`plan.tsv` 列（制表符分隔，无表头）：

| action | kind | dest | source | sha256 | extra |
|---|---|---|---|---|---|
| `reg` | `dir`/`file` | 要登记的绝对路径 | — | — | — |
| `link` | `dir`/`file` | 软链位置 | 软链目标 | — | — |
| `rc` | `file` | rc 文件 | scratch 里的新内容 | 新内容 sha256 | 被替换掉的旧块 sha256 或 `-` |

**为什么用 TSV 而不是 shell 代码**：py 生成 shell 代码需要自己做引号转义，路径里一个空格就出事故；TSV + `IFS='\t' read` 没有这个问题。

---

## 4. install / uninstall 语义

### install

1. **前置检查**（任一失败即拒绝）：
   - 项目目录存在且含 `wtool.xml`
   - 在 git 工作区内且**已跟踪文件无未提交改动**（`git status --porcelain -uno`）
   - ⚠️ **不检查分支**：repo 工具默认 detached HEAD，查分支会直接卡死
   - 不在 git 工作区 → 拒绝（`--force` 可跳过，仅用于测试/临时目录）
2. **冲突检查**：
   - `dest` 已存在于 registry 且属于别的项目 → 拒绝（`--force` 降级为警告）
   - `dest` 存在且不是软链 → 拒绝（`--force` 备份为 `*.wtool-bak.<时间戳>` 后接管）
   - `dest` 是软链但指向别处 → 拒绝（同上）
3. **执行**：建 `~/.wtool/links/<id>` 中转链接 → 建项目内软链 → 写 rc 块。
4. **落账**：写 `meta.tsv`、更新 `registry.tsv`、追加 journal（按 `(action,dest)` 去重）。

重复 install = **restow**（等价于 GNU Stow 的 `stow -R`）：已正确的软链不重建，rc 块原地更新，plan 为空时打印"没有需要变更的内容"。

### uninstall

1. 由 py 计算 rc 块移除后的内容；**先校验 journal 里记录的块 sha 与磁盘上现存的块 sha 是否一致**，不一致则拒绝（`--force` 强行移除）。
2. 落盘 rc 新内容。
3. **逆序重放 journal**：
   - `link` → 仅当它仍是软链**且指向仍与记录一致**时删除；否则警告并跳过
   - `mkdir` → 仅当为空时 `rmdir`
   - `backup` → 若原文件已不存在则还原
4. 删除 `$WTOOL_STATE/<id>/`（连带清理空掉的父目录）。

`uninstall --id <id>` 可在**仓库已经被删掉**的情况下使用。

---

## 5. 受管块格式

```sh
# >>> wtool:<id> schema=1 engine=1.0.0 prio=50 head=<commit> manifest=<sha12> >>>
WTOOL_PROJECT_ID='<id>'
WTOOL_PROJECT_DIR="$HOME/.wtool/links/<id>"
export WTOOL_PROJECT_ID WTOOL_PROJECT_DIR
WTOOL_PROJECT_ROOT=$(readlink -f -- "$WTOOL_PROJECT_DIR" 2>/dev/null || printf '%s' "$WTOOL_PROJECT_DIR")
export WTOOL_PROJECT_ROOT
[ -r "$WTOOL_PROJECT_DIR/<env-file>" ] && . "$WTOOL_PROJECT_DIR/<env-file>"
# <<< wtool:<id> <<<
```

| 字段 | 用途 | 变化频率 |
|---|---|---|
| `<id>` | 项目身份，也是块边界标记 | 几乎不变（改了要重装） |
| `schema` | 清单格式版本，引擎据此判断能否解析 | 极少 |
| `engine` | 引擎版本，用于诊断/未来兼容判断 | 每次发版 |
| `prio` | 排序键，决定块之间的先后 | 项目自己定 |
| `head` | 安装时的 commit（溯源） | 每次提交 |
| `manifest` | `wtool.xml` 的内容 sha256 前 12 位 | 清单改动时 |

**刻意不放时间戳**：块是契约不是日志；任何会随"重新执行"变化的字段都会破坏幂等（这是实测踩出来的 bug，见 `tests` 场景 2）。时间等信息记在 `meta.tsv`。

三个 `WTOOL_PROJECT_*` 变量**只在 source 期间有效**——多个项目的块会依次覆盖它们。
env 文件应当立刻把它们拷进自己的变量（例：`export WTOOL_TMUX_DIR="$WTOOL_PROJECT_DIR"`）。
`WTOOL_PROJECT_ROOT` 在 source 时由中转链接实时解析，所以仓库搬家后它自动指向新位置。

四条设计要点：

1. **`[ -r ... ] &&` 守卫**：仓库被删/搬走后，shell 不报错。
2. **只走中转链接**：块里不出现仓库真实路径，所以仓库可以随便搬。
3. **排序插入而非盲目 append**：插入点是"最后一个排序小于我的块之后"，因此与安装顺序无关。
4. **块内容只依赖 `<id>`**：搬仓库后 rc 文件字节不变（测试场景 8 验证）。

---

## 6. hash 策略

| 记录项 | 位置 | 变化频率 | uninstall 时的校验强度 |
|---|---|---|---|
| `engine` | 块 + `meta.tsv` | 每次发版 | 仅提示（未来 major 不匹配可拒绝） |
| `head` | 块 + `meta.tsv` | 每次提交 | **仅提示**：仓库变新是正常的，不该阻断卸载 |
| `manifest` sha | 块 + `meta.tsv` | 清单改动时 | 仅提示 |
| **rc 块内容 sha** | journal | 写入/重装时 | **严格**：与磁盘不符说明块被改过 → 拒绝（`--force` 可强行） |

结论：**用"逻辑版本"做硬校验，用"内容版本"做提示**。只记 HEAD 一个 hash 会导致"改一行配置就卸不掉"，这是我们明确要避免的。

---

## 7. 向后兼容承诺

| 承诺 | 做法 |
|---|---|
| 未知 `schema` → 拒绝并提示升级 bootstrap | `SCHEMA_SUPPORTED` 白名单 |
| 未知元素 → 报错（而不是静默忽略） | 避免拼写错误悄悄生效；自定义元素保留 `x-*` 前缀 |
| 未知属性 → 目前静默忽略 | 便于老引擎读新清单的"降级运行" |
| `plan.tsv` 列只增不改 | sh 读取时用 `read -r a b c d e f`，多余列被忽略 |
| 存根只依赖 `$WTOOL_BOOTSTRAP` 和 `wtool.sh` 的 `install|uninstall` 子命令 | 引擎内部重构不影响项目 |
| journal/registry 格式用 TSV 且按列读取 | 未来加列不影响老版本解析 |

**版本号规则**：`MAJOR.MINOR.PATCH`。MAJOR 变化 = 契约不兼容（清单或块格式），此时引擎必须能同时读懂旧 schema；MINOR = 新增能力；PATCH = 修 bug。

---

## 8. 未来方向（预留，尚未实现）

| 能力 | 设计草案 | 为什么现在就要想 |
|---|---|---|
| **system scope（写 $HOME 之外）** | `<copy src= dest=/etc/... scope="system"/>`，必须显式 `--allow-system` + sudo，且**不记入 journal**（不可逆），只输出"如何手工撤销" | mytool 的 `os` 项目要改 `/etc/apt/sources.list` |
| **多 shell** | `shells="zsh,bash"` 已支持；`fish`/`nu` 需要新的 rc 注入策略 | 项目里 `env` 只写 zsh 是现状，先按 zsh 落地 |
| **`--exact`** | uninstall 时用 `head` 从 git 历史取出当时的 `wtool.xml` 推导逆操作 | 比 journal 更严，但 journal 已经够用 |
| **`--prune`** | install 时把"清单里已删除但 journal 里还在"的软链一并清掉 | 目前 uninstall 会清，install 不会 |
| **`wtool` 命令本身** | 把 `wtool.sh` 软链到 `~/.local/bin/wtool`，支持 `wtool install <dir>` | 需要 `~/.local/bin` 在 PATH（由某个项目的 env 提供） |
| **锁** | 并发 install 时对 `$WTOOL_STATE` 加 flock | 多终端同时装才会撞 |

---

## 9. 已验证行为

`tests/pairing_test.sh`（全部在临时 `$HOME` 里跑，不碰真实系统）：

| # | 场景 | 断言 |
|---|---|---|
| 1 | install → uninstall | `$HOME` 文件树字节级回到安装前；原 rc 内容不变 |
| 2 | 重复 install | 文件树与 rc 内容都不变；报告"无变更" |
| 3 | 安装顺序无关 | 两种顺序得到相同的块顺序，且低优先级在前 |
| 4 | 脏仓库 / 非 git | 均被拒绝 |
| 5 | 软链被换成真实文件 | uninstall 不删用户文件 |
| 6 | `--dry-run` | 零副作用且输出计划 |
| 7 | 连续 3 次 install 后 uninstall | 仍完全回退（回归：曾因 journal 被清空而失败） |
| 8 | rc 块加载 env / 仓库搬家 | env 变量被正确导出；搬仓库后 rc 块字节不变、`WTOOL_PROJECT_ROOT` 指向新位置 |

共 27 条断言。跑法：

```sh
./tests/run_all.sh           # 四组全跑：pairing 27 + provision 24 + publish 20 + table 23
./tests/pairing_test.sh      # 只跑这一组
```

---

## 10. 环境变量契约（谁提供、何时有效）

分清三类，避免"以为配好了其实没有"：

| 类 | 变量 | 谁产生 | 何时有效 | 重启 shell 后 |
|---|---|---|---|---|
| **A 长期** | `WTOOL_PREFIX` | `bootstrap` 项目的 `env.zsh`/`env.bash` | 每次开 shell | ✅ 有 |
| **A 长期** | `WTOOL_OS_ID` / `WTOOL_OS_VERSION` / `WTOOL_OS_CODENAME` / `WTOOL_OS_LIKE` | 同上（`lib/wtool_os.sh` 读 `/etc/os-release`） | 每次开 shell | ✅ 有 |
| **A 长期** | `WTOOL_ARCH` / `WTOOL_JOBS` | 同上 | 每次开 shell | ✅ 有 |
| **A 长期** | `PATH` += `$WTOOL_PREFIX/bin` 和 `$WTOOL_PROJECT_DIR/bin`（`wtool` 命令） | 同上 | 每次开 shell | ✅ 有 |
| **B 构建期** | `WTOOL_SRC_DIR` / `WTOOL_REF` | 引擎在跑 `wsw.sh` 前临时注入 | 仅该次构建 | ❌ 不该有 |
| **C source 期** | `WTOOL_PROJECT_ID` / `WTOOL_PROJECT_DIR` / `WTOOL_PROJECT_ROOT` | rc 块 | source 期间（会被后加载的块覆盖） | ⚠️ 有但只对最后一个块成立 |

**设计原则：引擎自足。** `wtool` 命令不依赖 shell 里有没有这些变量——
`WTOOL_HOME/STATE/ROOT/PREFIX` 由引擎自己推导，`WTOOL_OS_*`/`ARCH`/`JOBS`
由引擎现场探测（`wt_os_detect`），`WTOOL_SRC_DIR`/`REF` 从项目 `wtool.xml` 读。
所以在 docker 里 `wtool provision` 也能正确工作，哪怕 shell 一个变量都没导出。

**B 类为什么不能进 shell**：它描述的是"这一次构建"而不是"这台机器的常态"。
`WTOOL_REF=v0.10.4` 只对 nvim 有意义；两个项目同时构建时还会互相覆盖。

**`WTOOL_PREFIX` 的语义**：编译安装的唯一前缀，`wsw.sh` 只准往这里写。
卸载 = 删掉 `$WTOOL_PREFIX` 下对应文件（不需要 journal）。

---

## 11. provision 层（不可逆操作，与 install 分离）

`install` 只做可逆的事（软链 + rc 块 + 系统文件），`provision` 做**不可逆**的事
（装包、编译）。两者永不互相调用。

```sh
wtool.sh provision <项目> [--dry-run] [--force] [--with-system]
wtool.sh bootstrap          [--with-system] [--dry-run] [--force] [--no-system]
```

`bootstrap` = 扫描工作区所有 `wtool.xml`（按 priority）→ 逐个 provision → 逐个 install。

### 三个阶段（顺序固定）

| 阶段 | 清单元素 | 可逆？ | 需要 root？ |
|---|---|---|---|
| 1. 系统文件 | `<system-file>` | **是**（备份/还原，进 journal） | 是（能直写就不 sudo） |
| 2. 上游源码 | `<source>` | 否（构建缓存，journal 记 `srcdir`） | 否 |
| 3. 任务 | `<provision>` | 否（只记 marker 与日志） | 视任务而定 |

### `<system-file>`：换源等

| 属性 | 说明 |
|---|---|
| `dest` | 绝对路径；与 `kind` 搭配时可用 `auto` 让引擎按发行版决定 |
| `src` | 项目内相对路径（自定义内容） |
| `kind` | `apt-mirror` / `yum-mirror` / `distro-mirror`：引擎按 `/etc/os-release` 生成 |
| `mirror` | `ustc` / `tuna` / `aliyun`（默认 `ustc`） |
| `mode` | `replace`（备份后覆盖）/ `add`（不存在才建）/ `disable`（原文件改名禁用） |
| `backup` | 默认 `replace` 时为 `true` |

语义：写前把原文件复制到 `$WTOOL_STATE/<id>/system/<slug>/original`，
journal 记 `sysfile`；`uninstall` 时从备份还原（原本不存在则删除，且只删内容仍是我们写的那份）。

**提权策略**：`id -u == 0` 或目标可写 → 直接写；否则用 `sudo`；都没有则报错。

### `<source>`：源码编译型项目（wsw.sh 约定）

| 属性 | 说明 |
|---|---|
| `url` | 上游仓库地址 |
| `ref` | **必填**，固定到 tag/commit（禁止浮动分支） |
| `dir` | 源码树位置，默认 `$WTOOL_SRC/<id 末段>`（`~/.wtool/src/...`） |
| `branch` | 本地分支名，默认 `wsw` |
| `overlay` | 项目内要铺进源码树的目录，默认 `overlay` |

执行：`clone/fetch` → `checkout --detach <ref>` → `checkout -B <branch>` →
把 `overlay/*` 复制进源码树 → **提交到 `wsw` 分支**（这样工作区干净、`git diff` 有意义）。

重跑时若源码树脏，且脏文件**全部来自 overlay** → 自动丢弃重铺；否则报错（`--force` 可强制）。

### `<provision>`：任务

| 属性 | 说明 |
|---|---|
| `src` | 脚本/playbook；解析顺序：源码树（overlay 铺入后）> 项目根 |
| `runner` | `ansible`（`.yaml/.yml` 默认）或 `shell` |
| `marker` | 幂等标记，成功后写 `$WTOOL_STATE/<id>/provisioned/<marker>`；重复执行会跳过 |
| `when` | 逗号分隔的 AND 条件：`os:ubuntu`、`!os:debian`、`arch:x86_64` |
| `desc` | 人类可读说明 |

任务环境变量（只在任务执行期间有效）：`WTOOL_PREFIX`、`WTOOL_SOURCE_DIR`、
`WTOOL_SOURCE_REF`、`WTOOL_PROJECT_ID/DIR/ROOT`、`WTOOL_OS_*`、`WTOOL_ARCH`、`WTOOL_JOBS`。

### journal 新增动作

| action | 含义 | uninstall 行为 |
|---|---|---|
| `sysfile` | 写过系统文件（记录备份路径与内容 sha） | 从备份还原 / 删除 |
| `srcdir` | 克隆过源码树 | 无未提交改动时删除 |

---

## 12. 前置依赖与 bootstrap 顺序（实测）

`wtool` 引擎需要：`sh`（POSIX）、**`python3`（3.6+，仅标准库）**、`git`。

各系统默认情况：

| 来源 | python3 | git | ca-certificates | apt 源协议 |
|---|---|---|---|---|
| Ubuntu **server/desktop ISO** 安装 | ✅ 有 | ❌ 缺 | ✅ 有 | HTTP |
| Ubuntu **docker 镜像** | ❌ **缺** | ❌ 缺 | ❌ 缺 | HTTP |

**因此首次引导的顺序是固定的**（顺序错了会陷在证书验证失败里）：

```sh
# 1) 用系统自带源装最小依赖（HTTP，不需要证书）
apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git python3
# 2) 换镜像源（HTTPS 现在能验证了）
# 3) wtool provision --with-system && wtool install
```

`wtool bootstrap` 必须在第 1 步之后才能跑；引擎检测到缺 `python3` 会直接报错。

---

## 13. publish 层（把项目发成 release 资产）

`install` 管"这台机器上装好了没有"，`provision` 管"系统层面备齐了没有"，
`publish` 管"这些东西怎么到另一台机器上"。

### 三种行为，由项目自己的 wtool.xml 声明

| 声明 | 行为 |
|---|---|
| 没有 `<publish>`，或 `<publish kind="source"/>` | 引擎打源码包，推到**项目自己 remote** 的 release |
| `<publish kind="script" script="publish.sh"/>` | 引擎只给环境和产物目录，脚本产出，引擎上传 |
| `<publish kind="none"/>` | 不发布（第三方上游仓等） |

属性：`tag`（strftime 模板，默认 `snapshot-%Y-%m-%d`）、`to`（推到别的仓）、
`asset`（资产名前缀）。子元素：

| 子元素 | 用途 |
|---|---|
| `<sub path=".." kind=".."/>` | 替子树里**没有 wtool.xml 的项目**表态 |
| `<target os=".." version=".."/>` | 目标系统矩阵，给 kind="script" 的脚本读 |

`<sub>` 存在的理由：上游仓（`neovim/neovim`）我们既没权限推 release，也**不能往里塞
wtool.xml**（那是别人的源码树）。所以"这个子项目不发布"这件事只能从伞项目外面声明。

### 源码包的形状

```
$ tar -C "$WTOOL_ROOT" --transform='s|^|wtool/|' --exclude='.git' -cf - terminal/tmux
wtool/terminal/tmux/bin/net.sh
wtool/terminal/tmux/install.sh
...
wtool/.wtool-dist/terminal-tmux.json     ← 发布副本标记
```

三个要点：

1. **第一层固定是 `wtool/`**，用 `--transform` 生成，跟本机工作区目录叫什么无关。
   发布产物不该依赖本机目录名——哪天把 `~/self/wtool` 改个名，所有包的形状就全歪了。
2. 解压到工作区的上一层（`tar -xf pkg -C ~/self/`），得到的路径和 `repo sync` 出来的
   **完全一致**。所以解压完 wtool 命令和表格直接可用——wtool 引擎不需要 `.repo`，
   那是 `repo` 工具自己要的。
3. 带 `--exclude='.git'`：解压副本不是 git 仓库，`--exclude` 去掉 `.git` 会让
   `install` 的前置检查拒绝。`.wtool-dist/<id>.json` 就是给这个用的标记，
   记下 `commit`/`repo`/`packed_at`，顺带补上块头里 `head=` 的溯源信息。

### 第三方仓保护

推送前查 `gh repo view <repo> --json viewerPermission`。没有写权限就拒绝并说明，
`--allow-foreign` 可以强行试。这样 `wtool publish` 不带参数扫全仓时，
不会撞到上游仓才失败。

### 命令

```sh
wtool publish                              # 发布所有声明过的项目
wtool publish tmux                         # 支持 id 末段
wtool publish terminal/tmux ./terminal/tmux  # 也支持完整 id 和路径
wtool publish astronvim_v5 --tag=v1 --dry-run
wtool publish tmux --out=/tmp/pkg          # 产物留在那里，先看看再传
```

`kind="script"` 的脚本能拿到的环境变量：`WTOOL_PUBLISH_PROJECT`、`_ROOT`、`_WS`、
`_REPO`、`_TAG`、`_OUT`、`_DATE`、`_FORCE`。全局设置 `WTOOL_PUBLISH_PREFIX` 可以改
`wtool/` 这个前缀名。**把要上传的文件放进 `$WTOOL_PUBLISH_OUT` 即可**，建 release 和
上传由引擎统一做——这样 gh 的调用、tag、权限检查只有一份实现，脚本也能单独 dry-run。

本地发布历史记在 `$WTOOL_STATE/<id>/publish.tsv`，离线也能在表格里看到发过没有。

### 实测

`tests/publish_test.sh`（20 条，全程用打桩的 `gh`，不碰网络和真 `$WTOOL_STATE`）：
源码包第一层是 `wtool/`、不含 `.git`、带 `.wtool-dist` 标记且 commit 对得上、
`kind="none"` 的项目不产生任何 gh 调用、脚本型项目的产出被完整上传。

---

## 14. 能力表格

`wtool`（不带参数）和 `wtool table` 都会打印：

```
┌──────────────────────┬──────┬────────────┬────────────┬────────────┬────────────┐
│ 项目                 │ prio │ build      │ download   │ install    │ publish    │
├──────────────────────┼──────┼────────────┼────────────┼────────────┼────────────┤
│ bootstrap            │ 5    │ 不支持     │ 不支持     │ 已完成     │ 可执行     │
│ editor/astronvim_v5  │ 70   │ 可执行     │ 可执行     │ 待构建下载 │ 待构建下载 │
└──────────────────────┴──────┴────────────┴────────────┴────────────┴────────────┘
```

**格子语义：四种状态，各带一个颜色。** 用的是方框字符而不是 ASCII ——
表格由 `render_table()` 按 CJK 双宽对齐算列宽，终端里不会错位。

| 状态 | 颜色 | 含义 |
|---|---|---|
| `不支持` | 红 | 这个项目没有这项能力 |
| `可执行` | 黄 | 有能力，现在就能跑 |
| `待构建下载` | 蓝 | 有能力，但要先 `build` 或 `download` |
| `已完成` | 绿 | 跑过了 |

> 这四种是**文字**不是符号，而且颜色只是辅助 —— 管道里（`--color=never`）
> 或色盲用户看到的仍然是可读的。早先版本用的是 `+ - .` 三种 ASCII 符号，
> 已经废弃：符号要靠图例才看得懂，而"不支持"和"还没做"这两件事
> 用一个 `.` 表示会混。

### 判定依据（只读文件，不写）

| 列 | 判定 |
|---|---|
| **能力有无** | 项目里有没有对应的东西：<br>`build`/`download` ← `scripts/build.sh` / `scripts/download.sh` 存在<br>`install` ← 有 `<link>`/`<env>`，或 `scripts/install.sh` 存在<br>`publish` ← `<publish kind>` 不是 `none` |
| **做没做过** | `$WTOOL_STATE/<id>/actions.tsv`（时间线，记 build/download）<br>`journal.tsv` / `registry.tsv`（install）<br>`provisioned/` + `system/`（provision）<br>`publish.tsv`（publish） |

**"文件存在即能力声明"**：新建一个空的 `scripts/build.sh` 会让那一列
立刻从「不支持」变成「可执行」。这是有意的 —— 能力由项目自己声明，
引擎不去猜。

**这两者要分开记：** 能力有无是**静态的**（看项目文件，不随运行变化），
做没做过是**动态的**（看状态目录）。填格子时先看能力，没有能力就是
「不支持」，有能力再看状态决定是「可执行」还是「已完成」。

`--verbose` 加逐项目细节，`--summary` 只打汇总行。
`--color=auto|always|never` 控制颜色，管道里自动关。

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
| **可迁移** | 仓库搬到任意路径，rc 块一个字都不用改（靠 `~/.wtool/wtool-work-dir/links/<id>` 中转） |
| **可撤销且可审计** | 撤销依据是 journal（"我做过什么"），不是"重新推导" |
| **两层不越权** | `install`/`uninstall` 永不 sudo、永不联网；`sudo-install`/`sudo-uninstall` 永不碰 `$HOME` 里的软链 |

六条不变量：

1. **仓外的一切改动，要么是软链，要么是受管块。** 没有第三种形态。
2. **每个动作都记进 journal。** uninstall 是逆序重放，不是重新计算。
3. **Python 只算不写。** 除 scratch 目录外，py 不产生任何副作用
   （`lib/wtool_zip.py` 是**工具**，和执行层的 tar/gzip 同级，由执行层调用）。
4. **Shell 只写不算。** 所有落盘动作集中在 `lib/wtool_fs.sh`，文本逻辑全在 py。
5. **要 sudo 的都叫 `sudo-*`；不叫 `sudo-*` 的永不要 sudo、永不联网。**
   推论：`wtool uninstall` **不还原 `/etc`**（那是 `sudo-uninstall` 的事），
   `sudo-uninstall` 也**不动 `$HOME` 里的软链**。
6. **系统层的账和用户层的账分开记**：install 的账在 `journal.tsv`（uninstall 会删），
   系统层的账在 `system.tsv` + `system/` + `apt.tsv`（只有 `sudo-uninstall` 才清）。

### 命令面

```
用户层（永不 sudo、永不联网）
  wtool install   <项目目录> [--dry-run] [--force] [--no-script]
  wtool uninstall <项目目录>|--id <id> [--dry-run] [--force] [--no-script]
  wtool bootstrap [--dry-run] [--force]            所有项目 install
  wtool check|repair [<项目>|all]                  声明/日志/磁盘对比；只重建不删除
  wtool status | doctor | validate | init | version

系统层（可能要 sudo、要联网）
  wtool sudo-install   <项目>...|all [--dry-run] [--force]
  wtool sudo-uninstall <项目>...|all [--dry-run] [--force]
  wtool sudo-bootstrap [--dry-run] [--force]

产物与发布
  wtool build|download <项目>...|all [--dry-run]
  wtool pack-release   <项目>... [--tag=T] [--repo=owner/repo] [--volume-size=32M]
  wtool unpack-release <项目>... [--from=目录]
  wtool publish        [<项目>...] [--tag=T] [--dry-run] [--force] [--out=DIR]

不可逆
  wtool kill-self-forever [--yes] [--dry-run]      删掉 wtool 的一切痕迹（含 state）
```

**删掉的命令**：`provision`（→ `sudo-install`，`--with-system` 一并删）、`table`（→ 裸跑 `wtool`）、
`list`（→ `status`）、`env`（→ `doctor`；`doctor --quiet` 只输出 export 行，可直接 eval）。
这些名字还在，但只会报错并告诉你现在该用什么。

### 两个角色：声明链接 vs 稳定地址

很多疑问都源于把这两者混为一谈：

| 角色 | 谁创建 | 在清单里声明吗 | 用途 | 例子 |
|---|---|---|---|---|
| **声明链接** | `<link>` | ✅ | "应用去这个位置找配置" | `~/.tmux.conf` |
| **稳定地址** | 引擎 install 时自动 | ❌ | "整个项目的稳定、防搬家路径"，供**配置内部互相引用** | `~/.wtool/wtool-work-dir/links/<id>`（指向项目根） |

**规则**：
- 清单只声明"应用去找的"链接；
- 配置文件**内部**要引用本项目其它文件时，写 `$HOME/.wtool/wtool-work-dir/links/<id>/...`（稳定地址），不要写仓库真实路径，也不要用 `$HOME` 之外的 env 变量（见下）。
- 为什么不能只靠 env 变量（如 `WTOOL_TMUX_DIR`）：tmux 的 `#()` 命令在**渲染时**用 `sh -c` 执行，`$HOME` 必然存在；而自定义 env 变量只有"启动 tmux server 的那个 shell 里 source 过它"才在。**`$HOME/.wtool/wtool-work-dir/links/<id>` 是唯一两者兼得的选择**（实测 tmux 3.4 验证）。

> 代价：`id` 因此成了**对外契约**，会同时出现在 `~/.wtool/wtool-work-dir/links/<id>`、rc 块、和配置文件的引用里。改 id = 改三处 + 重装。已写进本规范与 `terminal/tmux/wtool.xml` 的注释。

---

## 2. 角色划分

```
wtool-bootstrap/            引擎（全机器唯一一份）
├── wtool.sh                CLI：install / uninstall / sudo-install / sudo-uninstall /
│                           bootstrap / sudo-bootstrap / build / download /
│                           pack-release / unpack-release / publish /
│                           check / repair / status / doctor / validate /
│                           init / kill-self-forever
├── lib/wtool_plan.py       规划器：解析清单、校验、算 rc 新内容（只写 scratch）
├── lib/wtool_fs.sh         执行器：软链、原子写、journal、registry（唯一写 $HOME 的地方）
├── lib/wtool_zip.py        打包工具（zip 读写；中文名要 UTF-8 标志）
├── templates/*.tpl         项目脚本模板（wtool init --with-* 用）
└── tests/                  7 组断言：pairing / sudo-install / publish / table /
                            release-copy / release / contract

<项目>/                      数据（每个仓库一份）
├── wtool.xml               声明：shell 集成、链接表、系统层、优先级
├── env.zsh / env.bash      被 source 的部分（两个 shell 各一份，无副作用）
├── scripts/                动作：build.sh / download.sh / install.sh / publish.sh（按需）
├── release/                产物（编译 + 下载，.gitignore）
└── publish/                待上传目录：分卷 + dist.json（.gitignore）
```

状态（不在仓库里，属于这台机器）：

```
$WTOOL_STATE/                       默认 ~/.local/state/wtool
├── registry.tsv                    dest -> 项目id（全局视图，用于跨项目冲突检测）
└── <project-id>/
    ├── meta.tsv                    版本/来源/时间等溯源信息
    ├── journal.tsv                 用户层：install 做过什么（uninstall 逆序重放）
    ├── env.zsh / env.bash          这个项目的环境变量块（汇总文件的原料）
    ├── system.tsv                  系统层：/etc 写过的账（sudo-uninstall 的还原依据）
    ├── apt.tsv                     系统层：这次新装进来的 apt 包（快照差集）
    └── provisioned/<marker>        系统层：幂等标记
```

---

## 3. 数据流

```
install <项目>
  │
  ├─ sh: 前置检查（git 干净？拿到 HEAD；有 build/download 就先要 release/）
  │
  ├─ py plan-install ──► scratch/plan.tsv       引擎基建（中转链接 + env 块）
  │                     scratch/plan.home.tsv  声明面（$HOME 里的软链）
  │                     scratch/meta.tsv        project_id 等
  │
  └─ sh: ① 执行 plan.tsv       （中转链接 + env 块）
         ① 跑项目 install.sh  （release/ → ~/.wtool）
         ② 执行 plan.home.tsv （影子 HOME → $HOME）
         ③ wt_env_sync        （汇总 + ~/usr 这条全局软链）
```

**为什么拆成两张计划表**：`plan.home.tsv` 建的软链**指向**`install.sh` 铺出来的东西，
所以它必须等脚本跑完（§4.2）。执行顺序反过来就是先建一堆悬空链接。

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
   - **产物检查**：项目有 `scripts/build.sh` 或 `download.sh` ⟺ `release/` 必须存在且非空，
     否则拒绝并给出 `wtool build` / `wtool download` 两条命令（`--force` 降级为警告）。
     理由：`install` 是断网也要能跑的，它不替你去编译或下载。
2. **冲突检查**：
   - `dest` 已存在于 registry 且属于别的项目 → 拒绝（`--force` 降级为警告）
   - `dest` 存在且不是软链 → 拒绝（`--force` 备份为 `*.wtool-bak.<时间戳>` 后接管）
   - `dest` 是软链但指向别处 → 拒绝（同上）
3. **执行顺序（§4.2，别改回去）**：
   ```
   ① 引擎基建：中转链接 ~/.wtool/wtool-work-dir/links/<id> + 项目的 env 块
   ① 项目自己的 scripts/install.sh：release/ → ~/.wtool
   ② wtool.xml 的 link：~/.wtool/<wtool> → $HOME/<home>
   ③ wt_env_sync：env 汇总 + ~/usr 这条全局软链
   ```
4. **落账**：写 `meta.tsv`、更新 `registry.tsv`、追加 journal（按 `(action,dest)` 去重）。

重复 install = **restow**（等价于 GNU Stow 的 `stow -R`）：已正确的软链不重建，rc 块原地更新，plan 为空时打印"没有需要变更的内容"。

### uninstall

1. 先算出"**还有别的项目要这条软链吗**"：判据是磁盘上所有 wtool 项目的 `wtool.xml`
   （不是 registry —— registry 一条落点只有一个主人，而"两个项目都要 `~/.gitconfig`"
   完全合理）。有别人要用就留着，并把登记改到那个项目名下。
2. 由 py 计算 rc 块移除后的内容；**先校验 journal 里记录的块 sha 与磁盘上现存的块 sha 是否一致**，不一致则拒绝（`--force` 强行移除）。
3. 落盘 rc 新内容。
4. **逆序重放 journal**：
   - `link` → 仅当它仍是软链**且指向仍与记录一致**时删除；别人还要用的跳过；否则警告并跳过
   - `mkdir` → 仅当为空时 `rmdir`
   - `backup` → 若原文件已不存在则还原
   - `sysfile` → **不动**（系统文件归 `sudo-uninstall`，uninstall 不越权）
5. **最后**跑项目自己的 `scripts/install.sh --uninstall`（②' 拆 `$HOME` 软链 → ①' 跑脚本）。
6. 清理状态目录：**只删 install 自己的账**（`meta.tsv` / `journal.tsv` / `env.*` /
   `artifacts.tsv` / `actions.tsv` / `publish.tsv`）。系统层的账
   （`system.tsv` / `system/` / `apt.tsv` / `provisioned/`）**留着** ——
   删了，`sudo-uninstall` 就再也没依据还原了。

`uninstall --id <id>` 可在**仓库已经被删掉**的情况下使用。

### `~/usr` 这条全局软链

`~/usr` → `~/.wtool/usr` 是引擎自己建的**唯一一条**不属于任何项目的软链（§8）：

- 有项目装着就保证它在；一个项目都不剩就收走（`wt_env_sync` 全量重算时决定）
- **只删软链，不动 `~/.wtool/usr` 里的实体** —— 那是编译/下载产物，归 `uninstall` 和项目脚本管
- 它**不进 registry**（进去的话，最后一个项目卸完它还挂着，`~/usr` 就永远收不走）

---

## 5. 受管块格式

```sh
# >>> wtool:<id> schema=1 engine=1.0.0 prio=50 head=<commit> manifest=<sha12> >>>
WTOOL_PROJECT_ID='<id>'
WTOOL_PROJECT_DIR="$HOME/.wtool/wtool-work-dir/links/<id>"
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
| **旧标签继续认，但一定警告** | `<env>` / `<link src= dest=>` / `<provision>` / `<system-file>` / `<publish>` 解析照旧，`validate` 和每次解析都提示改成新标签；等所有项目迁完再删兼容分支 |
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

全部在临时目录里跑，不碰真实 `$HOME`、不碰 `/etc`、不连网：

| 组 | 文件 | 条数 | 守什么 |
|---|---|---|---|
| pairing | `tests/pairing_test.sh` | 33 | install → uninstall 字节级回退、幂等、顺序无关、脏仓库拒绝、dry-run、搬家、`doctor --quiet` 可 eval |
| sudo-install | `tests/provision_test.sh` | 24 | `/etc` 写入与备份、`sudo-uninstall` 还原、`<source>` 编译型、task 的 marker 幂等、when 过滤 |
| publish | `tests/publish_test.sh` | 41 | 源码包形状、相对软链不被改写、脚本型发布、第三方仓保护、gh 抖动时的复用 |
| table | `tests/table_test.sh` | 35 | 能力表格的格子语义与列对齐 |
| release-copy | `tests/release_copy_test.sh` | 17 | 从发布包解压出来的工作区（没有 `.git`、没有 repo 客户端） |
| release | `tests/release_test.sh` | 52 | pack-release 读 `.gitignore`、分卷、dist.json、downloads.sh、unpack-release 往返与拒绝坏卷 |
| contract | `tests/contract_test.sh` | 64 | 新标签、两跳软链、执行顺序、release/ 检查、`~/usr` 生命周期、认领检查、check/repair、kill |

共 **266** 条断言：

```sh
./tests/run_all.sh            # 7 组全跑
./tests/contract_test.sh      # 只跑这一组
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
所以在 docker 里 `wtool sudo-install` 也能正确工作，哪怕 shell 一个变量都没导出。

**B 类为什么不能进 shell**：它描述的是"这一次构建"而不是"这台机器的常态"。
`WTOOL_REF=v0.10.4` 只对 nvim 有意义；两个项目同时构建时还会互相覆盖。

**`WTOOL_PREFIX` 的语义**：编译安装的唯一前缀，`wsw.sh` 只准往这里写。
卸载 = 删掉 `$WTOOL_PREFIX` 下对应文件（不需要 journal）。

---

## 11. sudo 层（系统文件 / 源码 / 任务，与 install 分离）

`install` 只做用户层的事（软链 + rc 块），`sudo-install` 做系统层的事
（`/etc` 下的文件、apt 包、编译）。两者**永不互相调用**：`install` 永不 sudo，
`sudo-install` 永不碰 `$HOME` 里的软链。

```sh
wtool.sh sudo-install   <项目>...|all [--dry-run] [--force]
wtool.sh sudo-uninstall <项目>...|all [--dry-run] [--force]
wtool.sh sudo-bootstrap [--dry-run] [--force]        # 所有项目的 sudo-install
wtool.sh bootstrap      [--dry-run] [--force]        # 所有项目的 install（不做系统层）
```

**账分两份**（这是两层不互相踩的关键）：

| 账 | 文件 | 谁删 |
|---|---|---|
| 用户层 | journal.tsv / meta.tsv / env.* | `wtool uninstall`（逆序重放） |
| 系统层 | `system.tsv`（每行 `mode dest 原sha 新sha desc`）+ `system/<slug>/original` 备份 + `apt.tsv` + `provisioned/` | `wtool sudo-uninstall` |

所以 `wtool uninstall` 跑完之后，`wtool sudo-uninstall` **照样能还原 `/etc`**。

### 三个阶段（顺序固定）

| 阶段 | 清单元素 | 可逆？ | 需要 root？ |
|---|---|---|---|
| 1. 系统文件 | `<sudo-install … dest=/etc/…>` | **是**（三份备份 / 还原） | 是（能直写就不 sudo） |
| 2. 上游源码 | `<source>` | 否（构建缓存，journal 记 `srcdir`） | 否 |
| 3. 任务 | `<sudo-install src=…>` | 否（记 marker + **apt 差集**） | 视任务而定 |

### `<sudo-install dest=…>`：`/etc` 下的系统文件（换源等）

| 属性 | 说明 |
|---|---|
| `dest` | 绝对路径；与 `kind` 搭配时可用 `auto` 让引擎按发行版决定 |
| `src` | 项目内相对路径（自定义内容） |
| `kind` | `apt-mirror` / `yum-mirror` / `distro-mirror`：引擎按 `/etc/os-release` 生成 |
| `mirror` | `ustc` / `tuna` / `aliyun`（默认 `ustc`） |
| `mode` | `replace`（备份后覆盖）/ `add`（不存在才建）/ `disable`（原文件改名禁用） |
| `backup` | 默认 `replace` 时为 `true` |

语义：写前把原文件**备份三份**，各记 sha256：

| # | 位置 | 谁能写 |
|---|---|---|
| 1 | 原文件旁边：`/etc/…/x.conf.wtool-orig` | 目标可写就能写 |
| 2 | `/var/backups/wtool/<原始路径>` | **要 root**（非 root 时跳过并在输出里说明） |
| 3 | `$WTOOL_STATE/<id>/system/<slug>/original` | 永远写得了 |

还原时按 `1 → 2 → 3` 取第一份**校验通过**的；三份都对不上记录就报错拒绝（`--force` 才强行用），
**不许默默挑一份用**。`sudo-uninstall` 还原之后三份全删（价值已兑现，以后审计靠 journal 的文本记录）。
原本不存在 `dest` 的情况：还原 = 删掉它，且只删内容仍是我们写的那份（sha256 比对）。

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

### `<sudo-install src=…>`：任务（脚本 / playbook）

| 属性 | 说明 |
|---|---|
| `src` | 脚本/playbook；解析顺序：源码树（overlay 铺入后）> 项目根 |
| `runner` | `ansible`（`.yaml/.yml` 默认）或 `shell` |
| `marker` | 幂等标记，成功后写 `$WTOOL_STATE/<id>/provisioned/<marker>`；重复执行会跳过。`runner=` 已删（`.yaml/.yml` → ansible，其余 → shell） |
| `when` | 逗号分隔的 AND 条件：`os:ubuntu`、`!os:debian`、`arch:x86_64` |
| `desc` | 人类可读说明 |

任务环境变量（只在任务执行期间有效）：`WTOOL_PREFIX`、`WTOOL_SOURCE_DIR`、
`WTOOL_SOURCE_REF`、`WTOOL_PROJECT_ID/DIR/ROOT`、`WTOOL_OS_*`、`WTOOL_ARCH`、`WTOOL_JOBS`。

### journal 新增动作

| action | 含义 | 行为 |
|---|---|---|
| `sysfile` | 写过系统文件（记录备份路径与内容 sha） | 审计用；`uninstall` **不动**，`sudo-uninstall` 按 `system.tsv` 还原 |
| `srcdir` | 克隆过源码树 | `uninstall` 时无未提交改动就删除 |

**apt 差集**：`sudo-install` 在跑任务前后各取一次已装包快照（`dpkg-query -W`），
差集就是"这次新装进来的包"，记进 `apt.tsv`。`sudo-uninstall` 只卸这些
（`WTOOL_APT_GET` 可覆盖 apt-get，测试用）。不是 Debian 系（没有 dpkg）就跳过这一步。

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
# 3) wtool sudo-bootstrap && wtool bootstrap
```

`wtool bootstrap` 必须在第 1 步之后才能跑；引擎检测到缺 `python3` 会直接报错。

---

## 13. 发布层：pack-release / unpack-release / publish

`install` 管"这台机器上装好了没有"，`sudo-install` 管"系统层面备齐了没有"，
发布层管"这些东西怎么到另一台机器上"。

### 发布能力由**文件**声明，不由标签声明

`<publish>` 标签（含 `<sub>` / `<target>`）**整个删掉了**：能力来自文件存在 —

| 项目里有 | 行为 |
|---|---|
| `scripts/publish.sh` | 脚本型发布：引擎给环境和产物目录，脚本产出，引擎上传 `$WTOOL_PUBLISH_OUT` 里的文件 |
| 没有它 | 引擎自己打包（`pack-release`）再上传 |

老清单里的 `<publish>` 在过渡期仍然认，只用来表达两件文件表达不了的事：
推到别的仓（`to=`）和"不发布"（`kind="none"`，第三方上游仓要它）。

### pack-release：产出全部落在 `<项目>/publish/`

| 文件 | 内容 |
|---|---|
| `源码.zip` | 项目目录。**真读 `.gitignore`**（git 可用就让 `git ls-files -co --exclude-standard` 算，否则自带解析器），并永远排除 `release/`、`publish/`。包内第一层是 `wtool/<项目路径>/`，所以解压到工作区上一层得到的路径和 `repo sync` 一致；另带 `wtool/.wtool-dist/<id>.json` 发布副本标记（解压副本免 `--force`，`head=` 有出处） |
| `release.zip` | `release/` 里的东西 + **声明面**（`wtool.xml` / `env.zsh` / `env.bash`）。包内结构就是项目根的镜像，解压即到位 |
| `源码-hash.txt` / `release-hash.txt` | 各自的 sha256 |
| `dist.json` | 每卷的名字 / sha256 / 大小，**按顺序逐个声明** |

- 超过 `--volume-size`（默认 32M，或 `WTOOL_VOLUME_SIZE`）就切分卷 `<文件>-volNN`；
  **切开的原始大文件不留在 publish/**（它正是传不上去的那个）
- 纯声明式项目（没有 build/download、没有 `release/`）只有源码包 + 只带声明面的
  `release.zip` —— 只下 `release.zip` 的机器照样能 `wtool install`
- 归档是 zip，由 `lib/wtool_zip.py` 打（系统的 Info-ZIP 在这台机器上**不设 UTF-8
  名字标志**，中文名到别的工具里就是乱码；python3 的 zipfile 会设）
- **相对软链保留为软链**（不是拷成实体），指向不被改写

另外往**项目目录里**写两个文本（都是给人/给脚本看的，**要进 Git**）：

| 生成物 | 谁读 | 内容 |
|---|---|---|
| `scripts/downloads.sh` | `download.sh`（先定义 `wt_dl_add` 再 source 它） | 本次的 tag、base URL、每个资产的名字 + sha256 |
| `docs/download.md` | 人（浏览器） | 这版发了什么、直链在哪、下完敲哪条命令 |

**链接在上传前就算得出来**：`https://github.com/<owner>/<repo>/releases/download/<tag>/<文件名>`。
`pack-release` **不替你 commit**：跑完把该提交的打出来提醒。

### unpack-release：只认 dist.json，不需要项目特定知识

```
读 publish/dist.json → 逐卷校验 sha256 → 按顺序拼接 → 校验整个文件的 sha256
  → role=release 的解到项目根（里面有 release/ 和声明面）
  → role=source 的只校验、不铺开（install 只消费 release.zip）
```

一份都不缺才算成功；卷坏了 / 缺卷 / 拼接后 sha 不对 → **拒绝解开**（不许留下半个 `release/`）。
`--from=目录` 可以指到别处（下载目录），默认是 `<项目>/publish/`。
目标目录**允许还没有 `wtool.xml`** —— 声明面正是从这个包里解出来的。

### publish = pack-release + 上传

```sh
wtool publish                              # 所有可发布的项目
wtool publish tmux                         # 支持 id 末段、完整 id、路径
wtool publish astronvim_v5 --tag=v1 --dry-run
wtool publish tmux --out=/tmp/pkg          # 产物另拷一份出来，先看看再传
```

- 没有 `scripts/publish.sh` 的项目：`pack-release` → 上传 `publish/` 里的全部文件
- 有 `scripts/publish.sh` 的项目：调那个脚本（环境变量 `WTOOL_PUBLISH_PROJECT`、`_ROOT`、
  `_WS`、`_REPO`、`_TAG`、`_OUT`、`_DATE`、`_FORCE`），上传脚本产出的文件
- **第三方仓保护**：推送前查 `gh repo view <repo> --json viewerPermission`，没写权限就拒绝并
  说明怎么改（`--allow-foreign` 可以强行试）
- 上传失败**不以 0 退出**；产物保留，可直接补传（不必重新构建）
- 本地发布历史记在 `$WTOOL_STATE/<id>/publish.tsv`

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
| **能力有无** | 项目里有没有对应的东西：<br>`build`/`download` ← `scripts/build.sh` / `scripts/download.sh` 存在<br>`install` ← 有 `<link>`/`<zshrc>`/`<bashrc>`，或 `scripts/install.sh` 存在<br>`publish` ← `scripts/publish.sh` 存在（没有就是引擎打包的源码/发布包；老清单的 `<publish kind="none">` 仍然认） |
| **做没做过** | `$WTOOL_STATE/<id>/actions.tsv`（时间线，记 build/download）<br>`journal.tsv` / `registry.tsv`（install）<br>`system.tsv` + `provisioned/` + `apt.tsv`（sudo-install）<br>`publish.tsv`（publish） |

**"文件存在即能力声明"**：新建一个空的 `scripts/build.sh` 会让那一列
立刻从「不支持」变成「可执行」。这是有意的 —— 能力由项目自己声明，
引擎不去猜。

**这两者要分开记：** 能力有无是**静态的**（看项目文件，不随运行变化），
做没做过是**动态的**（看状态目录）。填格子时先看能力，没有能力就是
「不支持」，有能力再看状态决定是「可执行」还是「已完成」。

`--verbose` 加逐项目细节，`--summary` 只打汇总行。
`--color=auto|always|never` 控制颜色，管道里自动关。

---

## 15. 出问题时：check / repair / kill-self-forever

### `wtool check [<项目>]`

把**声明**（`wtool.xml`）、**日志**（journal / registry）、**磁盘**（真实的软链和文件）
三者摆在一起对比，**只报不改**。有问题时退出码非 0。

报的东西包括：软链不见了 / 被换成了实体 / 指向变了 / 声明了却从没装过（只有在明确
点名一个项目时才说）/ env 块丢了 / 汇总文件或 loader 块与"还有几个项目装着"对不上 /
`~/usr` 不见了或指向不对。

### `wtool repair [<项目>|all]`

修 `check` 报出来的，**只重建、不删除**：补中转链接、补 `$HOME` 软链、重写 env 块与汇总、
把 `~/usr` 重新接上。它**不跑项目自己的 `install.sh`** —— 那可能重新编译或联网下载，
不是"修一下"该干的事；实体确实没了就告诉你跑 `wtool install`。

### `wtool kill-self-forever [--yes]`

删掉 wtool 的一切痕迹（**不可逆**）。要求**逐字输入** `KILL-SELF-FOREVER`
（照抄 GitHub 删仓库的做法），并且输入之前先把"删什么、不删什么"列清楚：

| 删 | 不删 |
|---|---|
| `$HOME` 里 wtool 建的软链（只删还指向原位的） | apt 包、`/etc` 下的改动（那是 `sudo-uninstall` 的事） |
| `~/.wtool/`（含编译产物 `usr/`、自举副本、env 汇总） | 项目仓库本身（一个字节都不动） |
| `$WTOOL_STATE/`（装过什么、怎么撤的记录） | 用户自己的 rc 内容和手工建的东西 |
| `~/.zshrc` / `~/.bashrc` 里的 loader 块 | 引擎本体（工作区里的源码） |

`--yes` 跳过确认（给脚本用），`--dry-run` 只说不做。

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
| **provision（安装软件/编译）** | 清单加 `<task src="provision.sh" when="os:ubuntu"/>`；**独立子命令** `wtool provision`，不进 install | install 必须保持可逆；编译/apt 不可逆，混在一起就毁掉"完全配对" |
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

共 20 条断言。跑法：

```sh
./tests/pairing_test.sh      # 期望 PASS: 20  FAIL: 0
```

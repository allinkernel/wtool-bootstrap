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
| **可迁移** | 仓库搬到任意路径，**用户 rc 里那个 loader 块**一个字都不用改（靠 `~/.wtool/wtool-work-dir/links/<路径>` 中转）。⚠️ 但项目身份就是路径，所以改名要 `wtool move` —— 见 ADR-0037 |
| **可撤销且可审计** | 撤销依据是 journal（"我做过什么"），不是"重新推导" |
| **两层不越权** | `install`/`uninstall` 永不 sudo、永不联网；`sudo-install`/`sudo-uninstall` 永不碰 `$HOME` 里的软链 |

六条不变量：

1. **仓外的一切改动，要么是软链，要么是受管块。** 没有第三种形态。
2. **每个动作都记进 journal。** uninstall 是逆序重放，不是重新计算。
3. **Python 只算不写。** 除 scratch 目录外，py 不产生任何副作用
   （`lib/wtool_zip.py` 是**工具**，和执行层的 tar/gzip 同级，由执行层调用）。
4. **Shell 只写不算。** 受管的落盘动作集中在 `lib/wtool_fs.sh`，文本逻辑全在 py。
   （不是"只有它会写"：`wtool.sh` 也直接写状态目录，例如 `meta.tsv` 的追加，
   见 `wtool.sh:631-633`；`wtool_fs.sh` 管的是**软链 / rc / journal / 系统文件**这类受管写入。）
5. **要 sudo 的都叫 `sudo-*`；不叫 `sudo-*` 的永不要 sudo、永不联网。**
   推论：`wtool uninstall` **不还原 `/etc`**（那是 `sudo-uninstall` 的事），
   `sudo-uninstall` 也**不动 `$HOME` 里的软链**。
6. **系统层的账和用户层的账分开记**：install 的账在 `journal.tsv`（uninstall 会删），
   系统层的账在 `system.tsv` + `system/` + `apt.tsv`（只有 `sudo-uninstall` 才清）。

### 命令面

```
用户层（永不 sudo、永不联网）
  wtool install   <项目路径>|all [--dry-run] [--force] [--no-script]
  wtool uninstall <项目路径>|all [--dry-run] [--force] [--no-script]
  wtool move      <旧路径> <新路径> [--dry-run] [--force] [--no-script]
  wtool bootstrap [--dry-run] [--force]            所有项目 install（= install all）
  wtool check|repair [<项目>|all]                  声明/日志/磁盘对比；只重建不删除
  wtool status [<项目>]                           无参 = 登记表 + 软链检查；给项目 = 逐列状态 + 依据
  wtool doctor | validate | init | version

系统层（可能要 sudo、要联网）
  wtool sudo-install   <项目>...|all [--dry-run] [--force]
  wtool sudo-uninstall <项目>...|all [--dry-run] [--force]
  wtool sudo-bootstrap [--dry-run] [--force]

产物与发布（release 四条边：本地一对 pack/unpack，远端一对 publish/download）
  wtool build          [<项目>...|all] [--dry-run] [--target=<目标系统>] [--jobs=N] [--rebuild]
                                                       源码 → __output/（跑 scripts/build.sh 或引擎驱动容器；--rebuild = 无视"已经编好了"的三条判据）
  wtool pack-release   <项目>... [--tag=T] [--repo=owner/repo] [--volume-size=32M]
                                                         __output/ → __release/（**不联网**）
  wtool publish-release [<项目>...] [--tag=TAG] [--dry-run] [--force]
                        [--allow-foreign] [--out=DIR]     __release/ → GitHub Release（**只上传**）
  wtool download-release [<项目>...|all] [--dry-run]      GitHub Release → __release/（**只下载**）
  wtool unpack-release <项目>... [--from=目录]             __release/ → __output/（**不联网**）

层（第二条发布通道：容器镜像仓库，详见 §14）
  wtool _layer-save   <项目> --image=<镜像> [--target=<os_ver>] [--layer=<层名>]
                      docker 镜像 → __layer/<target>/（OCI 布局，blob 按 sha256 去重）
  wtool _layer-load   <项目> [--target=<os_ver>]
                      __layer/<target>/ → docker（接着构建 / 恢复容器）
  wtool unpack-layer <项目> [--layer=<层名>] [--target=<os_ver>] [--output=<目录>]
                      __layer/<target>/ 的顶层 blob → __output/<target>/<层>/。
                      **不联网、不要 docker**（直接读 blob）
  wtool push-layer   <项目>... [--registry=<前缀>] [--target=<os_ver>] [--layer=<层名>]
                      __layer/<target>/ 的层镜像 → 镜像仓库（构建机上跑，用 `docker push`）
  wtool pull-layer   <项目>... [--registry=<前缀>] [--target=<os_ver>] [--layer=<层名>]
                      镜像仓库 → __layer/<target>/。**目标机不需要 docker**，
                      只要一个 skopeo（缺了直接报错，告诉你 `apt install skopeo`）

不可逆
  wtool kill-self-forever [--yes] [--dry-run]      删掉 wtool 的一切痕迹（含 state）
```

五个层命令都认 `--dry-run`；`--registry=` 也可以由 `WTOOL_LAYER_REGISTRY` 提供。
`_layer-save` / `_layer-load` / `unpack-layer` 全是本地动作（和 `pack-release`/`unpack-release`
同级），**不碰网络**；只有 `pull-layer` / `push-layer` 要联网。
两个方向用的工具**故意不一样**：push 走 `docker push`（`crane push` 推大 blob 会
connection reset），pull 走 `skopeo`（它写 OCI 布局时会合并 `index.json`，而且不需要 docker）。

**帮助里没列的隐藏命令**：`wtool docs` / `wtool docs refresh` / `wtool refresh-downloads`
（三个入口同一个实现 `wt_refresh_downloads`）——按文档里的 `wtool:downloads` 标记块，
用 `gh release view` 查 GitHub 上**真实存在**的 release，重刷下载链接；
**查的是项目自己记着的那个 tag** —— 项目里提交在仓库中的 `scripts/release.json` 的 `tag`
（发布成功时写的，ADR-0026）；没有它（从没发布过）才退回按 `<publish tag=>` 模板算。
资产以 GitHub 上的实际存在为准；一个都没查到而文档里本来有表 → **拒绝用空表覆盖**
（`--force` 才清空）。生成块的命令按资产形状走（下载名带项目前缀、`.zip` 用 `unzip`、
`.tar.gz` 用 `tar -xf`、`dist.json`/`*-hash.txt` 不解、分卷先拼回）—— 见 ADR-0041；
没有标记块或没有 `gh` 就跳过。

**删掉的命令**：`provision`（→ `sudo-install`，`--with-system` 一并删）、`table`（→ 裸跑 `wtool`）、
`list`（→ `status`）、`env`（→ `doctor`；`doctor --quiet` 只输出 export 行，可直接 eval）、
`scaffold`（**整个删掉**，不是改名 —— 新建项目用 `wtool init <目录>`）。
这些名字还在，但只会报错并告诉你现在该用什么。

**`download` / `publish` 也删了，而且不留兼容窗口**：它们**语义变了**，所以是
`die` + 指路，不是"仍认但警告"（理由见 `docs/adr/0023`）：

| 旧名字 | 现在怎么敲 | 语义变在哪 |
|---|---|---|
| `wtool download` | `wtool download-release` + `wtool unpack-release` | 以前一步到 `__output/`；现在只把包下到 `__release/`，解包是另一条命令 |
| `wtool publish` | `wtool pack-release` + `wtool publish-release` | 以前打包 + 上传一条命令；现在只上传 `__release/` 里已有的东西 |

`wtool init` 的 `--with-download` / `--with-publish` 同样取消（项目脚本只剩两种，见 §14）。

### 两个角色：声明链接 vs 稳定地址

很多疑问都源于把这两者混为一谈：

| 角色 | 谁创建 | 在清单里声明吗 | 用途 | 例子 |
|---|---|---|---|---|
| **声明链接** | `<link>` | ✅ | "应用去这个位置找配置" | `~/.tmux.conf` |
| **稳定地址** | 引擎 install 时自动 | ❌ | "整个项目的稳定、防搬家路径"，供**配置内部互相引用** | `~/.wtool/wtool-work-dir/links/<路径>`（指向项目根） |

**规则**：
- 清单只声明"应用去找的"链接；
- 配置文件**内部**要引用本项目其它文件时，写 `$HOME/.wtool/wtool-work-dir/links/<路径>/...`（稳定地址），不要写仓库真实路径，也不要用 `$HOME` 之外的 env 变量（见下）。
- 为什么不能只靠 env 变量（如 `WTOOL_TMUX_DIR`）：tmux 的 `#()` 命令在**渲染时**用 `sh -c` 执行，`$HOME` 必然存在；而自定义 env 变量只有"启动 tmux server 的那个 shell 里 source 过它"才在。**`$HOME/.wtool/wtool-work-dir/links/<路径>` 是唯一两者兼得的选择**（实测 tmux 3.4 验证）。

> 代价：**路径**因此成了**对外契约**，会同时出现在 `~/.wtool/wtool-work-dir/links/<路径>`、rc 块、和配置文件的引用里。所以**改目录 = 换身份**，要走 `wtool move`（卸旧的 + mv + 装新的）；只 `mv` 会留下一整套对不上的旧账（`wtool check` 会报）。见 ADR-0037。

---

## 2. 角色划分

```
wtool-bootstrap/            引擎（全机器唯一一份）
├── wtool.sh                CLI：install / uninstall / sudo-install / sudo-uninstall /
│                           bootstrap / sudo-bootstrap / build /
│                           pack-release / publish-release / download-release / unpack-release /
│                           _layer-save / _layer-load / unpack-layer / push-layer / pull-layer /
│                           check / repair / status / doctor / validate /
│                           init / kill-self-forever（另有隐藏的 docs refresh）
├── lib/wtool_plan.py       规划器：解析清单、校验、算 rc 新内容（只写 scratch）
├── lib/wtool_fs.sh         执行器：软链、原子写、journal、registry（**受管**写入都走这里）
├── lib/wtool_zip.py        打包工具（zip 读写；中文名要 UTF-8 标志）
├── templates/*.tpl         项目脚本模板（wtool init --with-* 用）
└── tests/                  7 组断言：pairing / sudo-install / publish / table /
                            release-copy / release / contract

<项目>/                      数据（每个仓库一份）
├── wtool.xml               声明：shell 集成、链接表、系统层、优先级
├── env.zsh / env.bash      被 source 的部分（两个 shell 各一份，无副作用）
├── scripts/                动作，**只有两种**：build.sh（怎么编）/ install.sh（怎么铺）
│   └── release.json        下载声明（提交进仓库；publish-release 写，download-release 读）
├── docs/download.md        给人看的下载页（pack-release 写，进仓库）
├── __output/                 产物（.gitignore）—— **install 唯一读的目录**
└── __release/                包的中转站（.gitignore）：pack-release 的产出 + download-release 的落点
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
    ├── artifacts.tsv               产物账本：当前磁盘上的产物是谁产出的（ADR-0036）
    ├── build-logs/<target>/        引擎驱动构建（kind=docker）的每层日志 / plan / 指纹
    └── provisioned/<marker>        系统层：幂等标记
```

**`<project-id>` 里的 `/` 原样保留**（`$WTOOL_STATE/editor/astronvim_v5/…`）——
项目身份就是它的路径（ADR-0037），state 下所有东西（账本、日志、journal）都这一个拼法。
构建日志以前写成 `$WTOOL_STATE/editor_astronvim_v5/build-logs/`（`/` → `_`），
2026-10-04 统一掉了（ADR-0029 §3 的实现勘误）。

---

## 3. 数据流

```
install <项目>
  │
  ├─ sh: 前置检查（git 干净？拿到 HEAD；有 build.sh 就先要 __output/）
  │
  ├─ py plan-install ──► scratch/plan.tsv       引擎基建（中转链接 + env 块）
  │                     scratch/plan.home.tsv  声明面（$HOME 里的软链）
  │                     scratch/meta.tsv        project_id 等
  │
  └─ sh: ① 执行 plan.tsv       （中转链接 + env 块）
         ① 跑项目 install.sh  （__output/ → ~/.wtool）
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
| `envblock` | `zsh`/`bash` | 状态目录里的块文件 | scratch 里的新内容 | 新内容 sha256 | 项目内的 env 相对路径 |
| `unlink` | `dir`/`file` | 软链位置 | 期望指向（`-` = 不看） | — | — |
| `prune` | `dir`/`file` | journal 里的旧落点 | 当初的指向 | — | — |
| `prune-dir` | `dir` | journal 里"我们建过"的目录 | — | — | — |
| `regdel` | `dir`/`file` | 要注销的落点 | — | — | — |
| `write` / `remove` | `file` | 汇总文件 / loader 块 | scratch 里的新内容 | — | — |
| `envblock-del` | `zsh`/`bash` | 状态目录里的块文件 | — | — | — |

`link`/`reg` 出现在 `plan.tsv`（引擎基建）和 `plan.home.tsv`（声明面）两张表里；
`prune` / `prune-dir` **只有 `install --prune` 才会发**；`unlink` / `regdel` 是引擎收自己造的
全局软链（`~/usr`）用的。

**为什么用 TSV 而不是 shell 代码**：py 生成 shell 代码需要自己做引号转义，路径里一个空格就出事故；TSV + `IFS='\t' read` 没有这个问题。

---

## 4. install / uninstall 语义

### install

1. **前置检查**（任一失败即拒绝）：
   - 项目目录存在且含 `wtool.xml`
   - 在 git 工作区内且**已跟踪文件无未提交改动**（`git status --porcelain -uno`）
   - ⚠️ **不检查分支**：repo 工具默认 detached HEAD，查分支会直接卡死
   - 不在 git 工作区 → 拒绝（`--force` 可跳过，仅用于测试/临时目录）
   - **产物检查**：项目有 `scripts/build.sh` ⟺ `__output/` 必须存在且非空，
     否则拒绝，并给出两条产出路径 —— `wtool download-release` + `wtool unpack-release`（下现成的），
     或 `wtool build`（自己编）（`--force` 降级为警告）。
     理由：`install` 是断网也要能跑的，它不替你去编译或下载。
2. **冲突检查**：
   - `dest` 已存在于 registry 且属于别的项目 → 拒绝（`--force` 降级为警告）
   - `dest` 存在且不是软链 → 拒绝（`--force` 备份为 `*.wtool-bak.<时间戳>` 后接管）
   - `dest` 是软链但指向别处 → 拒绝（同上）
3. **执行顺序（§4.2，别改回去）**：
   ```
   ① 引擎基建：中转链接 ~/.wtool/wtool-work-dir/links/<路径> + 项目的 env 块
   ① 项目自己的 scripts/install.sh：__output/ → ~/.wtool
   ② wtool.xml 的 link：~/.wtool/<wtool> → $HOME/<home>
   ③ wt_env_sync：env 汇总 + ~/usr 这条全局软链
   ```
4. **落账**：写 `meta.tsv`、更新 `registry.tsv`、追加 journal（按 `(action,dest)` 去重）。

重复 install = **restow**（等价于 GNU Stow 的 `stow -R`）：已正确的软链不重建，rc 块原地更新，plan 为空时打印"没有需要变更的内容"。

#### `install --prune`（BL-15）

从 `wtool.xml` 里**删掉**一条 `<link>` 之后重装，旧软链还留在磁盘上（journal 里也还在），
一直到 uninstall 才清 —— 这是默认行为（restow 不删别人没让它删的东西）。
`--prune` 是显式的收尾清理，判据是 **journal**（"我做过什么"）而不是扫磁盘：

| 情况 | 动作 |
|---|---|
| journal 里有 `link`、这次清单里没有它 | `prune`：删软链（**先验还指向当初那个目标**）+ 清 registry + 销掉这条账 |
| journal 里有 `mkdir`、目录已经没人用 | `prune-dir`：**只有空目录**才 `rmdir`（非空一律留着），并把账销掉 |
| 落点在 registry 里已经归**别的项目** | 不删（链接搬了家，留给那个项目） |
| 不是我们建的软链（journal 里没有） | 不碰 —— 扫磁盘"看着像我们的就删"会删掉用户自己的东西 |

默认关（opt-in）：`wtool install <项目> --prune`、`wtool install all --prune` 都认；
`--dry-run` 只打印计划。

### `--dry-run` 的语义（现状，2026-10-04 用户拍板）

**只打印计划，绝不执行操作。**（用户原话："`--dry-run` 只打印计划就够，不要执行操作"。）
`--dry-run` 是**全局**开关：分发处先扫一遍参数，各命令不用自己认。

| 谁 | dry-run 时的行为 |
|---|---|
| 引擎自己的动作（软链 / rc / env 块 / journal / registry / 状态目录 / 删路径 / 打包 / 层） | 只打 `[dry-run] …` 的计划行，一个字节都不写；**不拿写锁**（§「全局写锁」） |
| **项目自己的 `scripts/install.sh` / `scripts/build.sh`** | **不执行**。引擎打印"真跑的话会跑哪条"（见下），然后跳过 |
| 项目自己的 `install.sh --uninstall`（`wtool uninstall`） | 同上，打印的参数是 `--uninstall` |
| `sudo-install` 层的任务脚本 / apt / 系统文件 | 各分支自己打计划（`[dry-run]` 行），不执行 —— 和项目脚本那条路无关 |

项目脚本那条打印的形状（`wt_run_project_script`，`wtool.sh`）：

```
wtool: 项目脚本: 不执行（--dry-run）—— 真跑的话是这条：
wtool:   - 命令     : sh /path/to/scripts/install.sh --uninstall
wtool:   - 工作目录 : /path/to/project
wtool:   - 环境     : WTOOL_PREFIX=… WTOOL_HOME=… WTOOL_PROJECT_ID=…
wtool:              WTOOL_ARTIFACTS=… WTOOL_STATE_DIR=…
```

**为什么不"把 `--dry-run` 转给项目脚本，让脚本自己打计划"**
（2026-10-04 之前的做法，也是那句错误注释的来源）：
**项目脚本认不认这个开关，引擎管不了。** 实测：`templates/{install,build}.sh.tpl`
里 0 处 dry-run；当年拿一个真实项目脚本（`tools/gerrit-gate/scripts/install.sh`，
2026-10-09 该项目已搬出本工作区）实测过 `--dry-run` 照样 `ln -s` 建软链 ——
**那个脚本现在不在了，这条复现没法原地重跑**，只留作当时的记录。
引擎能保证的只有自己这一层，所以干脆不进脚本这条路。当时的复现思路与判据见
`tests/contract_test.sh` 场景 15 的文件头；断言在场景 15（前后 `find` 清单逐行相同 +
没跑脚本 + 打印了脚本路径 / 工作目录 / `WTOOL_PREFIX`）。

> 项目脚本**仍然可以**自己支持 `--dry-run`（人工直接跑 `sh scripts/build.sh --dry-run`
> 时有用），但引擎**不再依赖**它，也不会替它传这个开关 —— 支持不支持都不影响
> `wtool <命令> --dry-run` 的零副作用。模板里有一段照抄用的写法。

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

#### 项目只能按**路径**给（ADR-0037）

`--id` 已经**删掉**（2026-10-04 用户拍板：项目身份就是它的路径）。
老写法会给一句指路的报错，而不是"未知参数"：

```
$ wtool uninstall --id terminal/tmux
wtool: error: --id 已经删掉：项目身份就是它的路径，直接写路径就行
  wtool uninstall terminal/tmux        （原来是 wtool uninstall --id terminal/tmux）
```

| 形式 | 解析 |
|---|---|
| `uninstall <路径>` | 路径**就是**身份。目录还在就直接用；目录不在了（被删 / 改过名）就按这条相对路径去 state 的账里找 |
| `uninstall <路径> --no-script` | 同上，但不跑项目脚本（"只撤 state 的账"） |

解析走 `wt_resolve_uninstall_path`（`wtool.sh`，原 `wt_resolve_uninstall_id`）：
① 工作区项目表（`publish-list`，看板 / 发布 / 状态用的是同一张表；**只认完整路径**），
② 表里没有就退回 `$WTOOL_STATE/<路径>/meta.tsv` 里 install 当时记的 `project_root`。

> **只认完整路径**：`wtool uninstall tmux` **不**替你猜 `terminal/tmux`。
> 理由是 state 里的账按完整路径建目录 —— 表里只有 `x/foo/bar` 而 state 里是
> `foo/bar` 时会卸错项目。找不到时把末段同名的候选列出来
> （"路径要写完整"），但不替你选。

### `~/usr` 这条全局软链

`~/usr` → `~/.wtool/usr` 是引擎自己建的**唯一一条**不属于任何项目的软链（§8）：

- 有项目装着就保证它在；一个项目都不剩就收走（`wt_env_sync` 全量重算时决定）
- **只删软链，不动 `~/.wtool/usr` 里的实体** —— 那是编译/下载产物，归 `uninstall` 和项目脚本管
- 它**不进 registry**（进去的话，最后一个项目卸完它还挂着，`~/usr` 就永远收不走）

### 全局写锁（BL-17）

`registry.tsv` / `journal.tsv` / env 汇总都是"读—改—写"：两个终端同时改，
最后落盘的那个会把前一个的条目抹掉（和 `__layer/index.json` 那次是同一类问题，
见 `harness/docs/hazards.md` H17）。所以**改状态目录的命令**统一走一把目录锁：

| 谁拿锁 | `install` / `uninstall` / `bootstrap` / `sudo-install` / `sudo-uninstall` /
`sudo-bootstrap` / `repair` / `kill-self-forever` |
|---|---|
| 锁在哪 | `$WTOOL_STATE/.lock`（目录当锁，里面写占用者的 pid） |
| 等多久 | 默认 300 秒，`WTOOL_LOCK_TIMEOUT=<秒>` 可改；`=0` 表示立刻失败 |
| 谁不拿锁 | `build` / `download-release` / `pack-release` 这类**长命令**（它们改的是
`__output/` 和 `__layer/`，不是账本；锁一整轮构建会让人白等）和 `--dry-run`（一个字节都不写） |
| 占用者死了 | pid 检查兜底：`kill -0` 不通就把锁抢过来，**不会永久卡住** |
| 可重入 | 拿锁的进程导出 `WTOOL_LOCK_OWNER=$$`；子进程（项目脚本里再调 `wtool`）
看到它就既不抢锁、也不替父进程放锁 |

超时时的报错是一条能照做的信息（谁占着、等它跑完、或 `WTOOL_LOCK_TIMEOUT=0`），
不是一个光秃秃的"失败"。

---

## 5. 受管块格式

```sh
# >>> wtool:<路径> schema=1 engine=1.0.0 prio=50 head=<commit> manifest=<sha12> >>>
WTOOL_PROJECT_ID='<路径>'
WTOOL_PROJECT_DIR="$HOME/.wtool/wtool-work-dir/links/<路径>"
export WTOOL_PROJECT_ID WTOOL_PROJECT_DIR
WTOOL_PROJECT_ROOT=$(readlink -f -- "$WTOOL_PROJECT_DIR" 2>/dev/null || printf '%s' "$WTOOL_PROJECT_DIR")
export WTOOL_PROJECT_ROOT
[ -r "$WTOOL_PROJECT_DIR/<env-file>" ] && . "$WTOOL_PROJECT_DIR/<env-file>"
# <<< wtool:<路径> <<<
```

| 字段 | 用途 | 变化频率 |
|---|---|---|
| `<路径>` | 项目身份，也是块边界标记 | 几乎不变（改了要重装） |
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
4. **块内容只依赖 `<路径>`**：搬仓库后 rc 文件字节不变（测试场景 8 验证）。

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
| 未知元素 → 报错（而不是静默忽略），**`x-*` 也一样报错** | 避免拼写错误悄悄生效。`<wtool>` 里**没有**"留给用户的自定义元素"这回事：`lib/wtool_plan.py` 对任何不认识的标签都拒绝（实测 `<x-note>` → `error: 未知元素 <x-note>`，退出码 1）。报错本身给出真出路（`<include src="wtool.local.xml" optional="true"/>`），**不再**教人写 `x-*`（那是它刚拒绝的东西，照做还是同一个错 —— BL-23） |
| 未知属性 → 目前静默忽略 | 便于老引擎读新清单的"降级运行" |
| **旧标签继续认，但一定警告** | `<env>` / `<link src= dest=>` / `<provision>` / `<system-file>` 解析照旧，`validate` 和每次解析都提示改成新标签；等所有项目迁完再删兼容分支 |
| **删掉的命令不给兼容窗口** | `download` / `publish` 直接 `die` + 指路（语义变了，见 §1）；`provision` / `table` / `list` / `env` / `scaffold` 同理 |
| `plan.tsv` 列只增不改 | sh 读取时用 `read -r a b c d e f`，多余列被忽略 |
| 存根只依赖 `$WTOOL_BOOTSTRAP` 和 `wtool.sh` 的 `install|uninstall` 子命令 | 引擎内部重构不影响项目 |
| journal/registry 格式用 TSV 且按列读取 | 未来加列不影响老版本解析 |

**版本号规则**：`MAJOR.MINOR.PATCH`。MAJOR 变化 = 契约不兼容（清单或块格式），此时引擎必须能同时读懂旧 schema；MINOR = 新增能力；PATCH = 修 bug。

---

## 8. 未来方向（预留，尚未实现）

> **这张表已经移到 `harness/BACKLOG.md`**（2026-09-27 文档体系调整）——
> 对应那里的 **BL-16**（`--exact`），
> 以及"预留设计"一节（system scope / 多 shell / `wtool` 命令本身）。
> （**BL-15 `--prune` 与 BL-17 全局写锁已经实现** —— 见 §4 和 §4 末尾「全局写锁」。）
>
> 理由：契约文档只写**已经成立**的东西；"打算怎么做"属于 BACKLOG。

## 9. 已验证行为

全部在临时目录里跑，不碰真实 `$HOME`、不碰 `/etc`、不连网：

| 组 | 文件 | 条数 | 守什么 |
|---|---|---|---|
| pairing | `tests/pairing_test.sh` | 35 | install → uninstall 字节级回退、幂等、顺序无关、脏仓库拒绝、dry-run、搬家、`doctor --quiet` 可 eval |
| sudo-install | `tests/provision_test.sh` | 40 | `/etc` 写入与备份、`sudo-uninstall` 还原、`<source>` 编译型、task 的 marker 幂等、when 过滤 |
| publish | `tests/publish_test.sh` | 154 | 源码包形状、相对软链不被改写、第三方仓保护、gh 抖动时的复用、同名 commit 重发（非交互拒绝 / `--force` 放行）、**资产名全是 ASCII**（`--dry-run` 打出的清单 + `release.json` 的 `assets[]` —— H27 / ADR-0040）、**建 release 带 `--target=<被打包的 commit>`**（打包后又提交也不许拿 HEAD 顶替；拿不到就警告 + 不传）、**下载表刷新认发布声明里的 tag**（正反两面 + 没发布过的退回模板 + 前缀防撞名 + `unzip`/`tar` 分发 + 幂等） —— ADR-0041 场景 16/17 |
| table | `tests/table_test.sh` | 94 | 能力表格（11 列的格子语义与列对齐）、图例逐条写全命令名、`__output/` 这个词、两张纯 ASCII 图（install 的 route 2 只写 unpack-release；release 图里 download 落 `__release/`、unpack 才到 `__output/`）|
| release-copy | `tests/release_copy_test.sh` | 17 | 从发布包解压出来的工作区（没有 `.git`、没有 repo 客户端） |
| release | `tests/release_test.sh` | 109 | pack-release 读 `.gitignore`、分卷、dist.json、unpack-release 往返与拒绝坏卷、**`unpack-release --dry-run` 不写 `__output/`**、**`--from=<目录>` 真被用上**（这两个原来都被静默忽略/无守卫）、**资产名全是 ASCII + 上一版留下的中文名报一声再删**（H27 / ADR-0040）、**下载块生成器按资产形状生成**（前缀防撞名 / `unzip` 与 `tar` 分发 / 分卷 `cat` 拼回 / `Expand-Archive`、`copy /b` / 块里的命令名与安装入口与现状一致 —— ADR-0041 场景 9） |
| contract | `tests/contract_test.sh` | 250 | 新标签、两跳软链、执行顺序、__output/ 检查、`~/usr` 生命周期、认领检查、check/repair、kill、`<build kind>`（拒绝没 docker 的 docker 项目 + 形状决定 targets）、check 两个 shell 的汇总文件、`--prune`（三道刹车 + 幂等）、全局写锁（放锁 / 不硬闯 / 接管 / 可重入 / dry-run 不等锁）、Tab 补全（23 条候选 + `docs` 不进候选 + 内部命令不进候选 + `status` 两种形态 + 每个候选开关都真能被解析器认出来）、**`--dry-run` 不跑项目脚本**（前后 `find` 清单逐行相同）、**uninstall 按路径指项目、且真跑项目脚本**（标记文件 + 参数；解析不出来时明确报错、退出码非 0，`--no-script` 只警告 —— BL-47/BL-48）、**`--id` 老写法给指路**、**`wtool move` 收干净改名残留 + `--dry-run` 零副作用**、**手工 mv 的残渣 `wtool check` 必须报出来**（旧 env 块 / 悬空链 / registry 旧行 —— ADR-0037，场景 17） |
| docker-build | `tests/docker_build_test.sh` | 101 | `kind="docker"` 的**引擎驱动构建**：按 `build/{targets,layers}.tsv` 起容器 → commit → 落 `__layer/` → 导 `__output/`（一层镜像对一层 output）、续跑、从 `__layer/` 恢复、失败不 commit、`export.filter`、dry-run、清单报错、**产物账本**（格式/来源/整表重写幂等/dry-run 不写/看板「下gz包」四种来源值/按项目分开/一行一个层目录含 `lang/x`/失败路径也重写，ADR-0036）、**`--rebuild` 绕过三条跳过判据**、**导出被拒不留残骸且重跑不被当成已导出**、**代理与本地镜像目录真的传进容器**、**构建日志保留 `<项目 id>` 里的 `/`** |
| install-env | `tests/install_env_test.sh` | 67 | `install.sh` 第 0 步：镜像测速（按速度降序，不是字符串排序）、交互挑源 / 非交互自动选最快、换源前备份 + 不好用能退回去、`WTOOL_MIRROR=<代号|主机名|official>`、挑过一次就复用（`WTOOL_MIRROR=pick` 强制重测）、`container-raw.sh --user` 的**三件事**与提示文案不漂移 |
| layer | `tests/layer_test.sh` | 50 | `__layer/<target>/` 那棵 OCI 镜像目录：写/读、blob 去重、index 合并、`unpack-layer` 解 blob + `OWNED.tsv` 扫描（**被拒之后重跑不许被当成已导出**）、`push-layer`（打桩 docker）、`pull-layer`（打桩 skopeo）、老名字指路 |

共 **917** 条断言（2026-10-09 实测：`cd bootstrap/tests && ./run_all.sh`；
`run_all.sh` **文件头**注释里那几行逐组条数也同步成了这一版，但**以它跑出来的 PASS 行为准**）：

```sh
./tests/run_all.sh            # 10 组全跑
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
| **B 项目脚本期** | `WTOOL_PROJECT_ID` / `WTOOL_PROJECT_DIR`（= 项目目录）/ `WTOOL_PROJECT_ROOT` / `WTOOL_WORKSPACE` / `WTOOL_HOME` / `WTOOL_PREFIX` / `WTOOL_JOBS` / `WTOOL_ARCH` / `WTOOL_OS_ID` / `WTOOL_OS_VERSION` / `WTOOL_OS_CODENAME` / `WTOOL_OS_LIKE` / `WTOOL_ARTIFACTS` / `WTOOL_STATE_DIR` | 引擎在 `wt_run_project_script` 里临时注入（`wtool.sh:325-335`） | 仅该次项目脚本（build / install） | ❌ 不该有 |
| **B′ `<source>` 任务** | `WTOOL_SOURCE_DIR` / `WTOOL_SOURCE_REF` | 只有 `<source>` 任务额外拿得到（`lib/wtool_fs.sh:555-557`） | 仅该次任务 | ❌ 不该有 |
| **C source 期** | `WTOOL_PROJECT_ID` / `WTOOL_PROJECT_DIR` / `WTOOL_PROJECT_ROOT` | rc 块 | source 期间（会被后加载的块覆盖） | ⚠️ 有但只对最后一个块成立 |

> ⚠️ 旧文档里写的 **`WTOOL_SRC_DIR` / `WTOOL_REF` 在代码里根本不存在**
> （2026-09-27 全仓 grep 零命中）。要写项目脚本就照上表 B / B′ 的名字写。
> 源码树根那个变量叫 `WTOOL_SRC`（`wtool.sh:74`，默认 `~/.wtool/src`），
> 是引擎自己推导的，不是喂给脚本的。

**设计原则：引擎自足。** `wtool` 命令不依赖 shell 里有没有这些变量——
`WTOOL_HOME/STATE/ROOT/PREFIX/SRC` 由引擎自己推导，`WTOOL_OS_*`/`ARCH`/`JOBS`
由引擎现场探测（`wt_os_detect`），`<source>` 的 `dir=`/`ref=` 从项目 `wtool.xml` 读。
所以在 docker 里 `wtool sudo-install` 也能正确工作，哪怕 shell 一个变量都没导出。

**B 类为什么不能进 shell**：它描述的是"这一次脚本"而不是"这台机器的常态"。
`WTOOL_ARTIFACTS` 指向的是**这一轮**的产物表（`$WTOOL_STATE/<项目 id>/artifacts.tsv`）。

> **订正（2026-10-04）**：这里原来还有一句"两个项目同时 build 时还会互相覆盖"——
> **那是错的**，路径按**项目 id** 分开，`wtool build all` 时各写各的。
> 复现：临时工作区里两个项目（一个引擎驱动、一个自己跑 `build.sh`）各写各的账本 →
> 两份 `artifacts.tsv` 都在、planner 分别读到 `build:ubuntu_24.04` / `build:plain`。
> 断言在 `tests/docker_build_test.sh` 场景 8（一份账本四种来源值）和场景 9（不互相覆盖）。
> 以本条为准。

**`WTOOL_PREFIX` 的语义**：编译安装的唯一前缀，`wsw.sh` 只准往这里写。
卸载 = 删掉 `$WTOOL_PREFIX` 下对应文件（不需要 journal）。

**账本的格式**（ADR-0036，4 列 TAB，**一行一个层目录**）：

```
kind <TAB> 相对项目根的路径 <TAB> 来源 <TAB> 时间
payload	__output/ubuntu_22.04/main	build:ubuntu_22.04	2026-10-04T21:30:12+0800
payload	__output/ubuntu_22.04/lang/lua	build:ubuntu_22.04	2026-10-04T21:30:12+0800
```

层目录的判据是"**哪个目录里有 `OWNED.tsv`**"，不是"目录树的第几层" —— 层名可以带 `/`
（astronvim 的 `lang/lua`、`lang/python`…），按深度遍历会把它们压成一行 `lang`。
**整表重写**（先写临时文件再 `mv`，读的人不会撞见写了一半的表），而且
**成功和失败都重写**：账本说的是"当前磁盘上的产物是谁产出的"，一轮构建失败之后
磁盘上可能只剩一半 —— 只在成功时写 = 账本替已经不存在的层背书。

---

## 10.5 换源：`install.sh` 挑一次，系统层跟着走（ADR-0032）

`./install.sh` 的**第 0 步**会先给国内几个镜像站测速，画一张表让用户挑
（非交互时自动选最快的），再换源装包。原因：`apt-get update` 在官方源上实测
374 KB/s，而国内镜像同一个文件快十几倍 —— 而这一步要下几十 MB。

| 谁 | 写什么 | 依据 |
|---|---|---|
| `install.sh`（`install-env.sh`） | `/etc/apt/sources.list.d/wtool-mirror.sources` | 测速 + 用户挑的；结果记进 `<state>/mirror.txt` |
| 项目的 `<sudo-install kind="apt-mirror" mirror="auto"/>` | 一般**什么都不写** | 读 `<state>/mirror.txt`：有记录就跳过（有 `official` 也跳过），没有才按老默认 `ustc` 写 |

跳过时 planner 会发一条 `dedup`，让 shell 把**以前 wtool 生成的那份**重复源文件删掉
（机器原来的文件一个字节都不动，也不进 `system.tsv`）。
两处各写一份的后果实测过：apt 报 `configured multiple times`，ansible 装包任务失败
（见 `harness/docs/hazards.md` H20）。

`WTOOL_MIRROR=<代号|主机名|official>` 可以跳过测速直接指定；`official` = 不换源。

**挑过一次就不再测**：结果记在 `<state>/mirror.txt`，第二次跑 `install.sh` 直接接着用
（省掉 7 个索引、每个最多 3 秒的探测）。想重新测速：`WTOOL_MIRROR=pick ./install.sh`。
容器里的 `container-raw.sh --user <名字>` 也是走这套：它**只做三件事** ——
建那个普通用户（密码 `root`、`/etc/sudoers.d` 免密、uid 尽量对齐宿主）、
测速挑源（记录写进**那个用户**的 state，`install.sh` 之后读到的是同一份）、
装 `sudo` 这个包（基础镜像里**没有**它）。它**不跑 `./install.sh`**，
也不装 python3 / git / curl / ansible —— 那些是你进去之后自己敲的。
`install_env_test.sh` 第 8 节守着这条（多装一样、或者它自己跑了 install.sh，测试就红）。

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
| 3 | `$WTOOL_STATE/<路径>/system/<slug>/original` | 永远写得了 |

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
| `marker` | 幂等标记，成功后写 `$WTOOL_STATE/<路径>/provisioned/<marker>`；重复执行会跳过。`runner=` 已删（`.yaml/.yml` → ansible，其余 → shell） |
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

### 11.x `sudo-install` 的任务能拿到什么（2026-10-04 修正）

`<sudo-install src="provision/xxx.sh"/>` 跑起来时，注入的变量里**目录有三个**，
别再混用（混用的后果见 `harness/docs/hazards.md` H22）：

| 变量 | 值 | 用途 |
|---|---|---|
| `WTOOL_PROJECT_DIR` | **项目检出目录**（和 `build.sh` / `install.sh` 里一致） | 脚本读写项目自己的文件 |
| `WTOOL_PROJECT_ROOT` | 同上（`WTOOL_PROJECT_DIR` 的规范形式） | 同上 |
| `WTOOL_PROJECT_STATE_DIR` | `$WTOOL_STATE/<项目 id>`（journal / meta / apt.tsv / provisioned 记号） | 想自己记点什么的时候用 |

工作目录（`$PWD`）是 `$WTOOL_SOURCE_DIR`（有 `<source>` 的项目）或项目目录。

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

## 13. 构建层：`<build kind>` 决定形状与驱动方式（ADR-025 / ADR-0029）

`wtool build` 只做三件事：找 `scripts/build.sh`、**判断这台机器够不够**、把环境喂好跑它。

| 声明 | `__output/` 的形状 | `wtool build` 的前置判断 |
|---|---|---|
| `<build kind="local"/>`（默认） | `__output/<层>/…`（**没有** target 那一层） | 只查 `min-cores` / `min-mem` / `min-disk` |
| `<build kind="docker"/>` | `__output/<os>_<ver>/<层>/…` | 同上，**外加**：没有 docker 直接拒绝 |

- **拒绝发生在动手之前**：`build.sh` 一行都不会跑。理由见需求 4 —— 在一台编不了的机器上
  跑一小时再失败是最坏的体验，所以引擎读声明就知道，并给出可复制的出路
  （`download-release` → `unpack-release` → `install`）
- **拒绝时退出码非 0**：`wtool build all` 里别的项目照编，但整条命令不算成功
  （"什么也没干却退出 0"是最容易骗过调用方的一种失败）
- 门槛不写就用引擎默认值（4 核 / 8G 内存 / 10G 磁盘）；`--force` 可以把门槛降级成警告，
  **但不能把"没有 docker"变成能编**
- **形状由声明唯一确定，引擎不嗅探**：`release.json` 的 `targets[]` 就是按它算的
  （`local` → 空；`docker` → `__output/*/` 的目录名）。`local` 项目就算 `__output/` 下有
  `bin/`、`main/` 这样的目录，也不会被当成"发行版"
- `WTOOL_DOCKER=<路径>` 可以指定 docker 二进制（和 `WTOOL_SKOPEO` 一个路子）

### `kind="docker"`：引擎驱动容器（ADR-0029）

项目提供三份约定文件，**容器生命周期全归引擎**：

| 文件 | 内容 |
|---|---|
| `build/targets.tsv` | `<目标系统> <TAB> <基础镜像> [<TAB> 代号 [<TAB> glibc]]` |
| `build/layers.tsv` | `<层名> <TAB> <父层> <TAB> <镜像名> <TAB> <容器里跑的命令>`；父层 `-` = 从基础镜像出发，镜像名 `-` = 占位层（留一个空 output 层），命令里的 `{target}` 由引擎替换 |
| `build/export.filter` | 可选。导出时丢什么，一行一个 `tar --exclude` 通配，`#` 注释 |
| `build/system-paths` | 可选。**允许层里的软链指向包外面**的系统路径（ADR-0030）：按**路径分量**比（`/usr/bin/python` 不放行 `/usr/bin/python3`），放行了哪些记进产出事实的 `allowed_escaping`。不写 = 一条都不放行 |

引擎对每一层：**没有镜像就起容器 commit → 存进 `__layer/<target>/` → 从顶层 blob 导出
`__output/<target>/<层>/`**。三步的判据都是"磁盘上有没有"，所以重跑 `wtool build`
**接着走、不重编**；`docker` 存储被 prune 掉也能从 `__layer/` 装回来。

**`--rebuild`：无视这三条判据，强制重编**。三条各自独立（① docker 里有这个镜像、
② `__layer/<target>/` 里有这一层、③ `__output/<target>/<层>/OWNED.tsv` 在），
`--rebuild` 要**三条都绕过**：

| | 不带 `--rebuild` | 带 `--rebuild` |
|---|---|---|
| ① 镜像是现成的 | 跳过构建（`✓ X（docker 里已有，跳过）`） | **重跑容器**（`commit` 出新镜像） |
| ② `__layer/` 里已有这一层 | 不再 `docker save` | **重存**（同一层名的旧条目被**换掉**，不是并排留着） |
| ③ `__output/` 里有 `OWNED.tsv` | 跳过导出 | **重导**（旧产物整个换掉） |

占位层（镜像名 `-`）没有镜像可编，`--rebuild` 对它是"清掉旧的空产物、重建一个空的"。
不带 `--layer=`：`wtool build <项目> --target=<t> --rebuild` 重编这个目标的**每一层**
（按父层顺序，父层先编完子层才有出发点）。
不做 `--rebuild` 时的续跑语义、以及"哪一层失败就从哪一层接着走"都不变。

> `--rebuild` 让"编过了"不再等于"编的是现在这份源码" —— 改了 `layers.tsv` 的命令、
> 或者怀疑某一层是旧的，就用它，别去手工 `docker rmi` + 删 `__layer/` + 删 `__output/`
> 三件套（漏掉任何一件都会被对应的那条判据跳过）。

**导出是"先做在临时目录、校验通过才 rename 落位"**（2026-10-04 修）：`wt_layer_export`
先解到 `__output/<target>/.<层名>.export.<pid>/`，`wt_owned_scan` 校验通过才
`mv` 成 `__output/<target>/<层>/`。失败（例如层里有指向包外的软链）时**一个残骸都不留** ——
否则下一轮会被判据 ③ 当成"已经导出好了"，静默 rc=0（还要给账本记一行背书）。

**每层的日志**在 `$WTOOL_STATE/<项目 id>/build-logs/<target>/`：`<层>.log`（容器里的输出）、
`<层>.wtool.log`（引擎这一侧这一层的全过程）、`<层>.fingerprint.json`、`plan.tsv`。
容器用 `--network=host` 起（代理要它），宿主的 `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`/`NO_PROXY`
（大小写都认）原样传进去，日志里会写一行 `代理 : <值>` 或 `代理 : 直连`；
宿主有本地镜像目录（`WTOOL_MIRROR_DIR`，默认 `~/self/mirror`）时**只读**挂进 `/mirror`
（目录不存在就不挂 —— 挂了 docker 会自己建一个空的），日志里写 `本地镜像: <路径> → /mirror:ro`。

契约文件分两半（ADR-026 §4）：

| | 放哪 | 内容 |
|---|---|---|
| **输入指纹** | **镜像里** `/wtool-layer/layer.json`（跑命令之前写进这一层） | 基镜像 + **digest**（不只记 tag）、`build/fingerprints.tsv` 里项目声明的外部输入、源码 commit / dirty、引擎版本、时间 —— 从 registry 拉回来的层因此**能自述来历** |
| **产出事实** | `__layer/<target>/<层名>.json`（跟着层走，不提交） | `payload_files` / `payload_bytes` / `payload_sha256`（= `OWNED.tsv` 的 sha256，而它逐条记着每个文件的 sha256 / 软链目标）/ 导出时间 / 结构校验结果 |

事实文件就放在布局目录里 —— 实测 `docker load` **容忍**多出来的文件
（`tar -c -C 布局 . | docker load` 照样装得上）。`build/fingerprints.tsv` 是可选的，
一行一条 `<键> <TAB> <值>`（apt 包版本、上游 commit、外部下载物 sha256 都记这儿）。

谁驱动看**层清单在不在**：`kind=docker` 且有 `build/layers.tsv` → 引擎驱动；
只有 `build.sh` → 跑它（迁移前的形态）；两个都没有 → 拒绝（退出码非 0）。
`wtool build` 对 `docker` 项目多认 `--target=<目标系统>` 和 `--jobs=N`（层的并行上限），
以及 `--rebuild`（无视"已经编好了"的三条判据，强制重编）。
**层按依赖并行跑**：父层就绪即可开跑，上限 `--jobs=N` > `$WTOOL_LAYER_JOBS` > 2（默认 2）；
某层失败就不再开新的、等在跑的落地，整批算失败。
`--dry-run` 打印每一层的计划（外加一行 `--rebuild` 的说明），收尾语是
"dry-run：以上 N 个目标的计划，什么都没执行"—— **不是**"N 个目标就绪"（那时候
`__layer/` 和 `__output/` 里可能什么都没有）。



---

## 14. 发布层：release 的四条边

`install` 管"这台机器上装好了没有"，`sudo-install` 管"系统层面备齐了没有"，
发布层管"这些东西怎么到另一台机器上"。

**release 有四条边、各一条命令**，名字就是**宾语（`release`）+ 方向**；再加上产出那条 `build`：

```
  源码 ──wtool build──▶ __output/*
                          │
              ┌── pack-release ──┐
   __output/*   │                  │   __release/*  ──wtool publish-release──▶ GitHub Release
              └── unpack-release ┘               ◀──wtool download-release──
       │
       └──wtool install──▶ ~/.wtool/* ──(按 wtool.xml)──▶ ~/*
```

| 命令 | 从哪 | 到哪 | 要什么 |
|---|---|---|---|
| `wtool build` | 源码 | `__output/` | 项目的 `scripts/build.sh` |
| `wtool download-release` | GitHub Release | **`__release/`** | `curl` + 项目里**提交的** `scripts/release.json` |
| `wtool unpack-release` | `__release/` | **`__output/`** | 只读 `__release/dist.json`，**不联网** |
| `wtool pack-release` | `__output/` | `__release/` | 只读磁盘，**不联网** |
| `wtool publish-release` | `__release/` | GitHub Release | `gh` + 干净的工作区 |

两条铁律：

- **`install` 只读 `__output/`**，永远不读 `__release/`；
- **`pack-release` / `unpack-release` 是 `__output/` 与 `__release/` 之间唯一的搬运工。**

### 契约文件：声明进仓库，事实跟产物走

| 文件 | 谁写 | 在哪 | 干什么 |
|---|---|---|---|
| `scripts/release.json` | `publish-release`（**上传成功之后**写） | **提交进仓库** | **下载声明**：`repo` / `tag` / `base_url` / `commit` / `dirty` / `targets` / 每个资产的 `name` + `sha256` + `bytes`（另记 `published_at` 与引擎版本）。`download-release` **唯一**要读的东西 |
| `__release/dist.json` | `pack-release` | 跟包走（**不提交**） | **这一份怎么拼**：分卷顺序、每卷 sha256、声明面清单。`unpack-release` 读它 |
| `__release/.source` | `pack-release` 写 `packed` / `download-release` 写 `downloaded` | 跟包走（**不提交**） | 内部来源标记。`publish-release` 靠它拒绝"把刚下下来的包又传回去" |
| `docs/download.md` | `pack-release` | **提交进仓库** | 给人看的下载页：这版发了什么、直链在哪 |

`scripts/downloads.sh` **没有了**：那份"这次发了什么"的清单归 `scripts/release.json`。

**一句话**：**校验用可信清单，拼装用自带清单。**
`download-release` 读的是**提交在仓库里**的 `release.json`，所以它不需要"先信一个刚从网上
拿到的清单"；`dist.json` 和包同源，就只承担"拼装与自检"。代价是 `release.json` 必须
**在上传之后**写、**由人提交** —— 引擎不替你 commit。

> ⚠️ **今天防什么、不防什么**：`sha256` 证明的是**传输完整性**（"我下到的和清单里写的一致"），
> **不是真实性**（"这是作者发的"）。"清单提交在 git 里"挡住了"发布页被替换"；
> **"git 账号被替换"今天没有挡 —— 那要签名（minisign / ssh key），现在没做**。
> 别把"校验通过"读成"来源可信"（见 `docs/adr/0026`）。

`release.json` 里的 `targets` 现在只有 target 名字（`[{"target": "ubuntu_22.04"}]`）：
每个 target 的 `glibc` / `arch` 还没记（见 `harness/BACKLOG.md` BL-28），
所以 `download-release` 今天**不做**按 glibc 选包。

### 项目脚本只剩两种

| 脚本 | 谁跑 | 契约 |
|---|---|---|
| `scripts/build.sh` | `wtool build` | 产物落到 `__output/`（和下载解出来的位置完全一致），并写 `$WTOOL_ARTIFACTS` |
| `scripts/install.sh` | `wtool install` | `__output/` → `$WTOOL_PREFIX`（默认 `~/.wtool/usr`）；`--uninstall` 撤销它 |

`scripts/download.sh` / `scripts/publish.sh` / `scripts/extract.sh` **全部退休**（ADR-023）：
下载归 `download-release` + `unpack-release`，打包上传归 `pack-release` + `publish-release`，
所有项目走同一条引擎实现的路，项目侧不再各写一遍（曾经有个项目的 `download.sh` 815 行）。
**"文件存在即能力声明"这条原则不变，但只有这两种**（判定见 §15）。

### `<publish>`：只表达文件表达不了的两件事

没写 `<publish>` 就等于 `kind="source"`（打包源码 / 产物，推到本项目自己 remote 的 release）。
有效写法：

| 写法 | 行为 |
|---|---|
| `<publish/>` 或 `kind="source"`（默认） | 推到项目自己的 remote |
| `kind="none"` | 不发布（第三方上游仓等） |
| `to="owner/repo"` | 推到别的仓（默认取项目 remote） |
| `<sub path= kind= to=/>` | 替"子树里没有 `wtool.xml` 的项目"表态（上游仓不能往里塞清单文件） |
| `<target os= version= codename= image=/>` | 目标系统矩阵；引擎**只解析并透出**（`wtool_plan.py publish-info` 读得到），发布流程不消费 |

**`kind="script"` 和 `script=` 现在是清单错误**：`wtool validate` 直接拒绝 ——
`kind="script"` 报"只能是 `source` / `none`"，`script=` 报
"发布不再调项目脚本，构建逻辑放 `scripts/build.sh`"。

### pack-release：产出全部落在 `<项目>/__release/`

**打几个包，看项目有没有构建能力**（ADR-0039）：

| 项目 | 打什么 |
|---|---|
| **有**构建能力（`scripts/build.sh`，或 `kind="docker"` + `build/layers.tsv`），且 `__output/` 里有文件 | `source.zip` **和** `release.zip`（两个都打，行为不变） |
| **有**构建能力，但 `__output/` 是空的 | **报错**（那是"忘了 build"，装出来会是半成品） |
| **没有**构建能力（纯源码 / 纯声明式） | **只打 `source.zip`** |

判据是"**磁盘上有没有产物**"（`__output/` 里有没有文件）**加上**"它有没有本事产出产物"，
两半都看（`wtool_plan.py` 的 `has_build_capability()`，一处判据、多处复用）。
第三行为什么不再打 `release.zip`：那种项目 `__output/` 是空的，release 包里**只剩声明面**
（`wtool.xml` / `env.zsh` / `env.bash`）—— 实测 `terminal/tmux`：源码包 15 个文件 20060 字节、
release 包 3 个文件 2210 字节，而且那 3 个是源码包的**子集**，两个包发的是同一批东西。
反过来，一个**没有** `build.sh` 却手工放了 `__output/` 的项目照样两个包 —— 不静默丢东西。

> ‼️ **资产名一律 ASCII**（`source.zip` / `source-hash.txt`）：GitHub **不接受非 ASCII
> 资产名**，`源码.zip` 传上去会被它改写成 `default.zip` 且 `gh` 不报错 —— 下载页那两条
> 直链就 404（现象 / 复现见 `harness/docs/hazards.md` **H27**，决策见 **ADR-0040**）。
> 名字在 `lib/wtool_fs.sh` 里只定义一次（`WT_SOURCE_ZIP` / `WT_SOURCE_HASH`）。
> `pack-release` 重跑时会把上一版留下的中文名（`源码.zip` / `源码-hash.txt` /
> `源码.zip-vol*`）**报一声再删掉** —— 留着会被 `publish-release` 当资产传上去。

| 文件 | 内容 |
|---|---|
| `source.zip` | 项目目录。**真读 `.gitignore`**（git 可用就让 `git ls-files -co --exclude-standard` 算，否则自带解析器），并永远排除 `__output/`、`__release/`。包内第一层是 `wtool/<项目路径>/`，所以解压到工作区上一层得到的路径和 `repo sync` 一致；另带 `wtool/.wtool-dist/<路径（斜杠换成连字符）>.json` 发布副本标记（解压副本免 `--force`，`head=` 有出处） |
| `release.zip` | `__output/` 里的东西 + **声明面**（`wtool.xml` / `env.zsh` / `env.bash`）。包内结构就是项目根的镜像，解压即到位。**只在有构建产物时产出** |
| `source-hash.txt` | `source.zip` 的 sha256 |
| `release-hash.txt` | `release.zip` 的 sha256（只在有 `release.zip` 时写） |
| `dist.json` | 每卷的名字 / sha256 / 大小，**按顺序逐个声明**；`how` 跟着包的内容说（只有源码包时说"源码会铺回项目目录"） |
| `.source` | 内部来源标记：`packed` + repo / tag / commit / 时间（**不上传、不进清单**） |

- 超过 `--volume-size`（默认 32M，或 `WTOOL_VOLUME_SIZE`）就切分卷 `<文件>-volNN`；
  **切开的原始大文件不留在 __release/**（它正是传不上去的那个）
- 项目有 `build.sh` 而 `__output/` 是空的 → **报错**（那是"忘了 build"，装出来会是半成品）
- 归档是 zip，由 `lib/wtool_zip.py` 打（系统的 Info-ZIP 在这台机器上**不设 UTF-8
  名字标志**，包里的**条目名**有中文（`wtool-base/原理.md` 这种路径）到别的工具里
  就是乱码；python3 的 zipfile 会设）
- **相对软链保留为软链**（不是拷成实体），指向不被改写

另外往**项目目录里**写 `docs/download.md`（给人看的下载页，**要进 Git**）。
`__release/` 本身**不进 Git**：它是待上传目录，也是 `download-release` 的落点。
**链接在上传前就算得出来**（`https://github.com/<owner>/<repo>/releases/download/<tag>/<文件名>`），
所以下载页可以先写；但 `scripts/release.json` 要等上传成功才写。
`pack-release` **不替你 commit**：跑完把该提交的打出来提醒。

### download-release：只下载，不解包

```sh
wtool download-release                  # 列出提交了 scripts/release.json 的项目
wtool download-release editor/astronvim_v5
wtool download-release all              # 所有提交了 release.json 的项目
```

1. 读 `<项目>/scripts/release.json` —— **唯一的输入**，而且它在仓库里（可信清单）。
   目录里没有它 → 警告并告诉你这个项目只能自己编（`wtool build`）
2. 逐个资产下到 `<项目>/__release/`（`base_url`，或按 `repo`/`tag` 拼出 GitHub 直链），
   **逐个校验 sha256**
3. **已经下好的跳过**（文件在、sha256 对得上）—— 重跑是幂等的，中断了重来不会坏
4. 直链不通时自动改走**第二条路**：`api.github.com` 的资产端点
   （`Accept: application/octet-stream`，跳到 `release-assets.githubusercontent.com`）
5. 下到东西就写 `__release/.source` = `downloaded`（`publish-release` 靠它拒绝回传）

约束与失败行为：

- 需要 `curl`；没有就直接报错（退出码 1）
- **不解包**：产出 `__output/` 是下一条命令 `wtool unpack-release <项目>` 的事
- 单个资产两条路都失败 → 警告"这个文件没下来"，**其余资产照下**；一个都没下来 → 警告
- 上面两种**退出码仍是 0**（只有参数错 / 缺 curl / 认不出项目才非 0）：
  部分失败要看输出里的 `warning`，**不能只看退出码**

### unpack-release：只认 dist.json，不需要项目特定知识

```
读 __release/dist.json → 逐卷校验 sha256 → 按顺序拼接 → 校验整个文件的 sha256
  → role=release 的解到项目根（里面有 __output/ 和声明面）
  → role=source 的：这一版**有**产物包 → 只校验、不铺开（install 只消费 release.zip）
                    这一版**没有**产物包 → 解到项目目录（源码就是产物，见下）
```

**源码包为什么分两种走法**（ADR-0039）：判据是 `dist.json` 里**有没有 `role=release`
的文件** —— 一个都没有 = 这一版只发了源码包（项目没有构建能力）。那时 `install` 要装的
东西全在源码里（`install.sh`、`bin/`、env 文件），**不铺开就是"install 时什么都没装"**。
铺的时候要把 `wtool/<项目相对路径>/` 整段前缀剥掉（前缀有几段取决于项目有多深），
并把 `wtool/.wtool-dist/<...>.json` 标记放到 `$WTOOL_ROOT/.wtool-dist/` ——
解压副本没有 `.git`，`install` 靠这个标记才认得出"这是发布副本"而不要求 `--force`。

一份都不缺才算成功；卷坏了 / 缺卷 / 拼接后 sha 不对 → **拒绝解开**（不许留下半个 `__output/`）。
`--from=目录` 可以指到别处（下载目录），默认是 `<项目>/__release/`。
**`--dry-run` 只打印计划**：不拼卷、不写 `__output/`（收尾语是"dry-run：以上 N 个文件的计划，
什么都没解开"）。文件在不在、卷够不够这类**只读**检查照做；拼卷之后才算得出来的 sha256
在 dry-run 里**不做**（明说"没校验"，不假装验过）。
目标目录**允许还没有 `wtool.xml`** —— 声明面正是从这个包里解出来的。

### publish-release：只上传

```sh
wtool publish-release                          # 所有可发布的项目
wtool publish-release tmux                     # 支持 id 末段、完整 id、路径
wtool publish-release astronvim_v5 --tag=v1 --dry-run
wtool publish-release tmux --out=/tmp/pkg      # 发布完把 __release/ 里的产物另拷一份到 DIR
```

- **只上传 `<项目>/__release/` 里已有的文件**（`find -maxdepth 1 -type f`，内部的 `.source`
  标记排除在外）。它**不替你打包**（没有 `dist.json` 就警告并提示先 `pack-release`），
  也**不再调任何项目脚本**
- `--dry-run` 除了"上传 N 个文件"，还会**把资产名逐个打出来** —— 发布前这是唯一能核对
  "线上会叫什么"的时机：GitHub **不接受非 ASCII 资产名**，非 ASCII 名传上去会被它
  改写成 `default.zip` 而 `gh` 不报错（**H27**、ADR-0040）。资产名现在一律 ASCII
- `__release/.source` 是 `downloaded` → **拒绝**："不能把别人打的包当自己的发出去"
- 项目不是 git 仓库、或工作区有**未提交改动** → 拒绝（`--force` 跳过；
  wtool 自己生成的文件 —— `release.json` / `download.md` —— 已豁免，否则一次发布会堵死下一次）
- **第三方仓保护**：推送前查 `gh repo view <repo> --json viewerPermission`，没写权限就拒绝并
  说明怎么改（写 `<publish to="自己的仓"/>` 或 `kind="none"`；`--allow-foreign` 可以强行试）
- 上传失败**不 die、不删产物**：警告、保住 `__release/`、继续下一个项目，可直接补传
  （不必重新构建）
- **同一个 commit 重发要问一句**（BL-03）：准备发布时拿 `scripts/release.json` 里记的
  `commit`（= 打包时那个 commit，来自 `dist.json`）和当前 HEAD 比 ——
  相同说明**内容一个字都不会变**，重发十有八九是手滑，或者上次传到一半断了：
  - **交互**（stdin 是终端）：打印这个 commit，问 `确定重发吗？[y/N]`，不答 y 就跳过这个项目；
  - **非交互**（stdin 不是终端，比如脚本 / 容器里跑）：**不猜**，直接拒绝并要求 `--force`
    —— 脚本里跑的命令绝不该卡在等输入上；
  - **`--force`**：跳过这个检查（"上次没传完，原样重传"就是这种）。
  注意它比的是**打包时那个 commit**，所以"改了代码但没重新 `pack-release`"不会被拦 ——
  那种情况发出去的还是老包，声明里也如实记着老 commit。
- **上传成功之后**才写 `scripts/release.json`（下载声明），并提醒你提交：
  清单必须等于"真传上去的那些文件"，所以要等上传结果
- `--out=DIR` 把这次发出去的产物**另拷一份**到 DIR（`__release/` 本来就留着，这只是方便你把
  产物拿走 —— 拷贝发生在发布之后，不是"先看再传"）
- 一个项目都没发出去 → **不改**下载文档（不拿"什么都没发生"覆盖现状）；本地发布历史
  记在 `$WTOOL_STATE/<路径>/publish.tsv`，记不上只警告（发布本身已经完成）
- 需要 `gh`（GitHub CLI）；没有就报错（退出码 1）
- 单个项目失败（脏仓库 / 没权限 / 上传断线）**退出码仍是 0**：看输出里的 `warning`

### 第二条通道：层（`_layer-save` / `_layer-load` / `unpack-layer` / `push-layer` / `pull-layer`）

发布包走 GitHub release 之外，还可以把**层镜像**放进镜像仓库。中心是 `<项目>/__layer/<target>/`
—— 一棵 **OCI 镜像布局**（ADR-024）：`oci-layout` + `index.json` + `blobs/sha256/…`，
blob 按内容命名所以父链天然只存一份。五条命令分工：

| 命令 | 方向 | 要什么 | 关键约束 |
|---|---|---|---|
| `_layer-save` | `docker` → `__layer/<target>/` | `docker` | `docker save <镜像> \| tar -x -C __layer/<target>/`（**tar 只当管道，不落盘**）；`index.json` 要**合并**（直接解第二个 `save` 会覆盖第一个的条目）；annotation 记 `io.wtool.layer` / `io.wtool.target` / `io.wtool.image` |
| `_layer-load` | `__layer/<target>/` → `docker` | `docker` | `tar -c -C __layer/<target>/ . \| docker load`，装回来是**同一个 image ID** |
| `unpack-layer` | `__layer/<target>/` → `__output/<target>/<层>/` | 什么都不用 | 顺着 `index.json → manifest → layers[-1]` 找到**顶层 blob**，直接解（`--strip-components=2` 剥掉 `root/.wtool`，丢掉 `.wh.` 白障），再扫一遍生成 `OWNED.tsv`。**不联网、不要 docker**；**解在临时目录、校验通过才 rename 落位** —— 被拒（层里有指向包外的软链）时 `__output/` 里不留残骸 |
| `push-layer` | `__layer/<target>/` → 镜像仓库 | **`docker`**（构建机上） | tag 是 `<层名（/ 换成 -）>-<target>`；先 `docker load` 整棵布局再 `docker push` —— **不是** `crane push`（它把整个 blob 塞进一个 PATCH，大层会被服务器 reset，且重试从 offset 0 重来） |
| `pull-layer` | 镜像仓库 → `__layer/<target>/` | **`skopeo`** | **目标机不需要 docker**；`skopeo copy --all docker://… oci:__layer/<target>:<tag>` —— skopeo 写布局时会**合并** `index.json`、blob 去重；拉完由引擎补上 `io.wtool.layer` / `io.wtool.target` annotation。缺 skopeo 直接 die 并告诉你 `apt install skopeo` |

- 层名里的 `/` 在 tag 里写成 `-`（`lang/lua` → `lang-lua`）；拉回来时**先看本地布局里
  有没有同 tag 的层名**，没有才按 `-` → `/` 还原（层名里同时有 `a-b` 和 `a/b` 会有歧义，
  本项目的层名不会撞）
- 落点：`unpack-layer` 解出来的是 `__output/<target>/<层>/`，和 `build.sh` 的产物**完全相同的
  路径**，所以 `pull-layer` → `unpack-layer` → `wtool install` 接得上
- `--registry=<前缀>` 或 `WTOOL_LAYER_REGISTRY`（形如
  `crpi-xxxx.cn-chengdu.personal.cr.aliyuncs.com/wtool-docker-registry`）；
  两个联网命令不给就报错，不猜
- 层的 `OWNED.tsv` 由 `unpack-layer` **扫出来**（不是从包里读的）：它会拒收**指向 payload
  外面**的软链（换台机器必然是断的），值为 `sha256` 或 `L:<软链原值>`
- `__layer/` 只对 `kind="docker"` 的项目存在（见 ADR-025）；`__layer/` 是**项目资产**，
  docker 存储只是缓存 —— `docker system prune` 之后 `_layer-load` 就装回来

## 15. 看板（裸跑 `wtool`）

裸跑 `wtool`（不带参数）打印**五段看板** + 两张图；`wtool table` 这个名字**已经删掉**，
敲它只会告诉你裸跑 `wtool`。分段与理由见 **ADR-0031**（用户 2026-09-29 提的要求）：
以前只有 `build` / `install` 两列，而引擎里逐项目的命令不止两条。

| 段 | 内容 |
|---|---|
| 1 | **能力表**：`build` / `install` / `uninstall` / `sudo` / `sudo-un` / `pack` / `publish` / `download` / `layer` 九列（+ 项目、prio）—— `install` / `sudo` 各自跟一列 uninstall，装之前是「未安装」、装完变「可执行」（ADR-0034）。**13 列**（`layer` 已拆成 unpack-layer / push-layer / pull-layer，一列一命令；长列名折两行）；**`sudo` / `sudo-un` 两列要看这台机器有没有 sudo**：每次跑都现探，没有就**不列那两列**（9 列），图例里说明原因（ADR-0035）|
| 2 | `wtool install` 能装哪些项目、装过没、会做什么 |
| 3 | `wtool sudo-install` 能装哪些项目、跑过没、会装什么 |
| 4 | `wtool bootstrap` 这次会装哪些、什么顺序、谁被跳过 |
| 5 | `wtool sudo-bootstrap` 这次会跑哪些 |
| — | 然后才是流水线说明和两张 **纯 ASCII** 图（安装 / 发布） |

```
┌──────────────────────┬──────┬────────┬─────────┬───────────┬────────┬─────────┬────────┬─────────┬──────────┬────────┐
│ 项目                 │ prio │ build  │ install │ uninstall │  sudo  │ sudo-un │  pack  │ publish │ download │ layer  │
├──────────────────────┼──────┼────────┼─────────┼───────────┼────────┼─────────┼────────┼─────────┼──────────┼────────┤
│ bootstrap            │ 5    │ 不支持 │ 已完成  │ 可执行    │ 不支持 │ 不支持  │ 可执行 │ 可执行  │ 未发布   │ 不支持 │
│ os/ubuntu            │ 5    │ 不支持 │ 不支持  │ 不支持    │ 已完成 │ 可执行  │ 可执行 │ 可执行  │ 未发布   │ 不支持 │
│ editor/astronvim_v5  │ 70   │ 可执行 │ 待产出  │ 未安装    │ 不支持 │ 不支持  │ 待产出 │ 可执行  │ 未发布   │ 可执行 │
└──────────────────────┴──────┴────────┴─────────┴───────────┴────────┴─────────┴────────┴─────────┴──────────┴────────┘
```

**列名 = 引擎命令**（表下面有一行图例，**一条都不省略**）：`build`=`wtool build`、
`install`=`wtool install`、`uninstall`=`wtool uninstall`、`sudo`=`wtool sudo-install`、
`sudo-un`=`wtool sudo-uninstall`、`pack`=`wtool pack-release`、`publish`=`wtool publish-release`、
`download`=`wtool download-release`、
`layer`=`wtool unpack-layer / wtool push-layer / wtool pull-layer`。
（`wtool _layer-save` / `wtool _layer-load` 是**内部命令**，不进图例 —— ADR-0034。）

> ⚠️ 这一条**不改 ADR-0023**：项目脚本仍然只有 `build.sh` / `install.sh`（那是"项目能力"）；
> 看板多出来的列是**引擎的**命令，逐项目地摆出来是为了让人一眼看到"这个项目还能做什么"。

**格子语义：六种状态，各带一个颜色。** 方框字符 + CJK 双宽对齐在 `render_dashboard()`
里算（终端里不会错位）；颜色只是辅助，`--color=never` 或色盲用户看到的仍然可读。

| 状态 | 颜色 | 含义 |
|---|---|---|
| `不支持` | 红 | 这个项目没有这项能力 |
| `可执行` | 黄 | 有能力，现在就能跑 |
| `待产出` | 蓝 | 能力有，但 **`__output/` 还是空的**：先 `wtool build`，或者 `download-release` + `unpack-release` |
| `已完成` | 绿 | 跑过了（各自的账：`actions.tsv` / `journal.tsv` / `publish.tsv` / `__layer/`） |
| `未发布` | 紫 | `download` 专有：仓库里**没有** `scripts/release.json`（还没发布过）—— 和"待产出"不是一回事 |
| `未安装` | 青 | `uninstall` / `sudo-un` 专有：**现在没什么可撤的**（还没装过）—— 和"不支持"不是一回事（ADR-0034）|

**三个开关**：`--brief`（只打第 1 段 + 图例 + 汇总行，`wtool doctor` 和 `bootstrap` 末尾用它）、
`--verbose`（多一段"明细"：装过什么时候、产物从哪来、发布过没）、
`--summary`（只打一行汇总，脚本用）、`--color=auto|always|never`。

### 判定依据（只读文件，不写）

| 列 | 能力有无（静态：看项目文件） | 做没做过 / 别的状态（动态：看状态目录、看磁盘） |
|---|---|---|
| `build` | `scripts/build.sh` 或 `build/layers.tsv` | `actions.tsv` 里有 `build` → `已完成` |
| `install` | 有 `<link>`/`<zshrc>`/`<bashrc>`，或 `scripts/install.sh` | `journal.tsv`/`registry.tsv` 记着 → `已完成`；有 `build` 能力而 `__output/` 空 → `待产出` |
| `sudo` | 清单里有 `sysfile`/`source`/`task` | `provisioned/` mark 或 `system/` 或 `apt.tsv` → `已完成` |
| `pack` | 永远可以（源码包谁都能打） | `__release/dist.json` 在 → `已完成`；有 `build` 能力而 `__output/` 空 → `待产出` |
| `publish` | `<publish kind="none"/>` → `不支持` | `publish.tsv` 有记录 → `已完成` |
| `download` | 仓库里提交了 `scripts/release.json` | 产物来自下载（`artifacts.tsv`）→ `已完成`；没提交声明 → `未发布` |
| `layer` | `build/layers.tsv` 在 | `__layer/<target>/index.json` 在 → `已完成` |

**`待产出` 永远是"看磁盘，不看做过没有"**：有能力而 `<项目>/__output/` 是空的 → `待产出`。
判据和 `wtool install` 的前置检查是同一件事（§4.1）——所以两处永远不会一个说能装、一个说没产出。

**"文件存在即能力声明"**：新建一个空的 `scripts/build.sh` 会让那一列
立刻从「不支持」变成「可执行」。这是有意的 —— 能力由项目自己声明，
引擎不去猜。**但只有 `build.sh` / `install.sh` 这两种算数**（§15）。

**这几者要分开记：** 能力有无是**静态的**（看项目文件，不随运行变化），
`已完成` 是**动态的**（看状态目录），`待产出` 看**磁盘**（`__output/`）。
填格子时先看能力，没有能力就是「不支持」；有能力再看状态：
装过 → `已完成`，否则 `__output/` 空且有 `build.sh` → `待产出`，其余 → `可执行`。

`--brief` 只要第 1 段 + 图例 + 汇总行（`wtool doctor` / `bootstrap` 末尾用）；
`--verbose` 再加一段"明细"；`--summary` 只打汇总行（脚本用）；
`--color=auto|always|never` 控制颜色，管道里自动关。

---

## 15.5 Tab 补全（`wtool <TAB>`）

补全的候选**由引擎自己算**，两个 shell 脚本只是转发 —— 命令清单只有一份
（`wtool.sh` 的 `WTOOL_SUBCOMMANDS` / `WTOOL_PROJECT_CMDS` / `wt_complete_flags`）：

```sh
wtool _complete <正在敲的词> [已经敲过的词...]   # 内部命令（下划线 = 不进 --help 主清单）
```

| 位置 | 补什么 |
|---|---|
| `wtool <TAB>` | 子命令（**没有 sudo 的机器上不提 `sudo-*`**，和看板一个口径）|
| `wtool install <TAB>` | 项目 id（`publish-list` 的前两列）+ `all` + 常用开关 |
| `wtool pack-release --<TAB>` | 那条命令**真的支持**的开关（表里只列存在的）|
| 都不是 | 什么都不补 → shell 退回**文件名**补全（路径参数照旧能补）|

两份脚本：`completion/wtool.bash`（`complete -F`）、`completion/wtool.zsh`
（`compdef`；compinit 没跑过时会自己跑一次，否则纯 zsh 下 Tab 只会补文件名）。
它们由 `bootstrap` 项目的 `env.bash` / `env.zsh` 自动 source —— 也就是
**装完 wtool、开个新 shell 就有**，不用手配。

`tests/contract_test.sh` 场景 13 守着：`WTOOL_SUBCOMMANDS` 那 **18** 条命令都在候选里
（实测 `sh bootstrap/wtool.sh _complete ''` 输出 18 行）、内部命令不在、
前缀过滤对、每个命令的开关补得出来、两个脚本被 env 挂上、bash 里
`complete -p wtool` 注册成功、zsh 里 `$_comps[wtool]` 是 `_wtool`。

---

## 16. 出问题时：check / repair / kill-self-forever

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

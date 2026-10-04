# 项目清单规范 `wtool.xml`

每个项目根目录放一份 `wtool.xml`。它是**纯声明**，不含逻辑。

## 最小可用清单

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="50">

  <zshrc  src="env.zsh"/>
  <bashrc src="env.bash"/>

  <link home="~/.tmux.conf"
        wtool="~/.wtool/.tmux.conf"
        subproject="tmux.conf"/>

</wtool>
```

**标签总表**（不认识的标签 `wtool validate` 直接报错）：

| 标签 | 用途 |
|---|---|
| `<zshrc src="env.zsh"/>` | 这份文件的内容进 `~/.wtool/.zshrc`（被 `~/.zshrc` 里的 loader 块 source） |
| `<bashrc src="env.bash"/>` | 同上，进 `~/.wtool/.bashrc` |
| `<link home= subproject= />` | 三段映射，见下（`wtool=` 可省，省了就按 `home=` 的镜像路径推） |
| `<link home= produced-by="install.sh"/>` | 同上，但中间那一跳由项目 `install.sh` 产出 |
| `<sudo-install src="provision/packages.yaml"/>` | 系统层：要跑的脚本 / playbook（要 sudo、要联网，不在 `install` 里跑） |
| `<sudo-install src="x.conf" dest="/etc/x.conf"/>` | 系统层：`/etc` 下的文件（可逆，备份/还原） |
| `<sudo-install kind="apt-mirror" mirror="ustc" dest="auto"/>` | 系统层：引擎按发行版生成内容（换源） |
| `<source url= ref= />` | 上游源码：clone → 固定 ref → 建本地分支 → 铺 overlay |
| `<build kind="local\|docker"/>` | 构建方式（ADR-025）：`local` 本地直接编（默认）、`docker` 每个发行版一个容器分层构建。可带 `min-cores=` / `min-mem=` / `min-disk=` 门槛 |
| `<publish kind= to= />` | 怎么发布（默认 `source`）：推到本项目 remote，或 `to=` 指定的仓、`kind="none"` 不发布 |
| `<include src= optional= />` | 拆清单 |

<small>⚠️ 表外的标签**一律报错**，`x-*` 也不行 —— 见文末「自定义元素」。
（旧版这张表里写过"`x-*` 自定义"，**那是错的**：`lib/wtool_plan.py:414-416` 对任何未知标签
都拒绝，实测 `<x-note>` → `error: 未知元素 <x-note>`、退出码 1。）</small>

---

## `<build>` —— 构建方式

```xml
<build kind="local"/>                                    <!-- 默认：本地直接编 -->
<build kind="docker" min-cores="8" min-mem="16" min-disk="40"/>
```

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `kind` | 否 | `local` | `local` = 本地直接编，产物天然跨发行版；`docker` = 每个发行版一个容器、分层构建。**别的值一律报错** |
| `min-cores` | 否 | 引擎默认 4 | 这台机器至少几个核，不够就拒绝构建并指路 `download-release` |
| `min-mem` | 否 | 引擎默认 8 | 内存 GB 数（按 `/proc/meminfo` 的 MemTotal 算） |
| `min-disk` | 否 | 引擎默认 10 | `$HOME` 所在分区至少剩多少 GB |

`kind` 决定**两件事**，引擎因此不用猜（ADR-025）：

1. **这台机器行不行** —— `kind="docker"` 而机器上没有 docker，
   `wtool build` 在**动手之前**就拒绝（`build.sh` 一行都不会跑），
   并给出 `download-release` + `unpack-release` + `install` 三条命令。
   这台机器够不够编，同样在跑脚本之前判断（不够就加 `--force` 硬上）。
2. **`__output/` 的形状**：

   | kind | `__output/` 下是什么 |
   |---|---|
   | `local` | `__output/<层>/…` —— **没有** `<os>_<ver>/` 那一层 |
   | `docker` | `__output/<os>_<ver>/<层>/…` |

   形状**由声明唯一确定**：`release.json` 的 `targets[]` 就是按这个算的
   （`local` → 空；`docker` → `__output/*/` 的目录名）。所以 `local` 项目的
   `__output/` 里就算有 `bin/`、`main/` 这种目录，也不会被当成"发行版"。

> 只声明 kind，**targets 和层清单不进 XML** —— 那是项目数据，住项目里固定路径的文件：
> `build/targets.tsv`（目标系统 → 基础镜像）、`build/layers.tsv`（层名 / 父层 / 镜像名 /
> 容器里跑的命令）、`build/export.filter`（导出时丢什么）。见 `harness/docs/adr/0029`。
> 有 `build/layers.tsv` 时**引擎驱动容器**（起容器 / commit / 落 `__layer/` / 导 `__output/`）；
> 只有 `scripts/build.sh` 时仍然跑脚本（迁移前的形态）；两个都没有就拒绝构建。

---

## `<wtool>` 根元素

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `schema` | ✅ | — | 清单格式版本。当前只支持 `1`；未知值会被拒绝 |
| `id` | ❌ **已删除** | — | **不要写**。项目身份**就是它相对工作区根的路径**（ADR-0037）。还写着 `id` 的清单会**直接报错**，删掉这个属性即可 |
| `priority` | 否 | `100` | 越小越早加载；`<zshrc>`/`<bashrc>` 不写 `priority` 时继承它 |

### 项目身份 = 路径（没有 `id` 这回事了）

用户 2026-10-04 拍板（ADR-0037）：**干掉项目 id，一律用项目路径指项目。**
原话："项目 id 是个很烦人的东西，直接干掉吧。我们后续就根据项目路径来指定项目即可。
否则改了路径，还要改 id，就很烦。"

所以：

- 身份**只有一个来源** —— 项目目录相对工作区根的路径（`terminal/tmux` 这样的）。
  它出现在 `~/.wtool/wtool-work-dir/links/<路径>`、`$WTOOL_STATE/<路径>/` 和 rc 块标记里。
- **改目录 = 换了一个项目**。想改名用 `wtool move <旧路径> <新路径>`
  （= 卸旧的 → mv → 装新的），别自己 `mv`。只 `mv` 会把旧路径那一套账
  （state 目录、中转软链、env 块、registry 行）留在原地，而且它们**大多不报错、
  只是静默失效**；`wtool check` 会把这类残渣报出来。
- 路径里**不要**用 `..`，也别写成绝对路径 —— 项目要待在工作区里。
  工作区**外面**的目录也能 `wtool install /abs/path`，但那种项目拿不到合法的相对路径，
  身份会退化成目录名（`basename`）：能用，但别指望它跨机器稳定。

---

## `<zshrc>` / `<bashrc>` —— 要被 source 的部分

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src` | ✅ | — | 相对本清单的相对路径 |
| `priority` | 否 | 根元素的 | 排序键 |
| `optional` | 否 | `false` | `src` 不存在时跳过 |

**两个 shell 各一份，内容要等价** —— 受众里有人机器上没有 zsh（公司机器很常见），
只写一份的后果是"那个 shell 的用户敲命令 `command not found`"，而 rc 文件里看起来
明明装过了。所以 `env.zsh` 改了，`env.bash` 要跟着改。

最容易漏的一句（症状：装完了但敲命令找不到）：

```sh
export PATH="$WTOOL_PREFIX/bin:$PATH"      # 装出来的东西
export PATH="$WTOOL_PROJECT_DIR/bin:$PATH" # 项目自己的 bin/
```

它最后进哪儿：

```
env.zsh  的内容 ──► ~/.wtool/.zshrc   ──► ~/.zshrc  里一个 loader 块 source 它
env.bash 的内容 ──► ~/.wtool/.bashrc  ──► ~/.bashrc 里一个 loader 块 source 它

每个 shell 一条**独立**的链：env.zsh 是给 zsh 用的，env.bash 是给 bash 用的（两份内容
等价，各自服务一个 shell）。汇总文件是所有项目共用的；rc 里的 loader 块是全局的、
不属于任何项目。只用 bash 的人靠的就是 env.bash 这条链。
```

`eval "$(wtool doctor --quiet)"` 能把同一批变量直接灌进当前 shell。

---

## `<link>` —— 三段映射

| 属性 | 必填 | 说明 | 写什么 |
|---|---|---|---|
| `home` | ✅ | `$HOME` 下的落点 | 写全，带 `~/` |
| `wtool` | 否 | `~/.wtool`（影子 HOME）下的落点 | **省掉就按镜像路径推**（`$HOME` 里的路径在 `~/.wtool` 下同名，`lib/wtool_plan.py:482-493`）；想放别处才写出来 |
| `subproject` | ✅ | 项目里的相对路径 | 内容从这儿来 |
| `produced-by` | 否 | 内容由谁产出 | 目前只认 `install.sh`（这时不写 `subproject`） |

所以下面两种写法等价，**短的那种就够**：

```xml
<link home="~/.foo.conf" wtool="~/.wtool/.foo.conf" subproject="foo.conf"/>
<link home="~/.foo.conf"                         subproject="foo.conf"/>
```

2026-09-27 实测：只写 `home=` + `subproject=` 的清单 `wtool validate` → `ok`，退出码 0。
`wtool=` 一旦写了，就必须落在 `~/.wtool/` 下面（写别处会被拒绝），
所以它只在"刻意不镜像"时才有信息量。

连起来是两跳：

```
<项目>/tmux.conf ──► ~/.wtool/.tmux.conf ──► ~/.tmux.conf
                  中间那一跳（实体落点）    最后一跳（应用找的位置）
```

**为什么要有中间那一跳**：项目目录挪位置（换机器、改工作区路径）不会把 `$HOME` 里的
链接弄断；而且 `~/.wtool/` 下看到的东西和 `$HOME` 一一对应，一眼就知道是谁装的。

目录、内容由项目自己的 `install.sh` 产出时：

```xml
<link home="~/.config/astronvim_v5"
      wtool="~/.wtool/.config/astronvim_v5"
      produced-by="install.sh"/>
```

这条软链由引擎铺，实体由 `install.sh` 铺 —— 所以 **`install.sh` 先跑、软链后建**
（见 `docs/spec.md` §4），顺序反了就是先建一堆悬空链接。

### 声明链接 vs 稳定地址

`<link>` 只声明"应用去找的"链接（如 `~/.tmux.conf`）。
`~/.wtool/wtool-work-dir/links/<id>` 是引擎 install 时**自动创建**、指向整个项目根的
"稳定地址"，**不要**在清单里声明。

**项目内部文件互相引用时用稳定地址**，例如 `tmux.conf` 里引用 `bin/` 脚本：

```
#($HOME/.wtool/wtool-work-dir/links/terminal/tmux/bin/mem.sh)
```

不要用自定义 env 变量（如 `$WTOOL_TMUX_DIR`）——tmux 的 `#()` 执行时 `$HOME` 必然存在，
而自定义变量只有启动 tmux server 的那个 shell 里有。详见 `docs/spec.md` §2。

---

## `<sudo-install>` —— 系统层（`/etc`、apt 包、要跑的脚本）

一个标签覆盖三类内容，靠有没有 `dest=` 区分：

```xml
<!-- 1) 要跑的脚本 / playbook（.yaml/.yml → ansible，其余 → shell） -->
<sudo-install src="provision/packages.yaml" marker="apt-base"
              when="os:ubuntu" desc="基础软件包"/>

<!-- 2) 项目里带的系统文件（可逆：备份三份 → 写 → 还原） -->
<sudo-install src="mirror.sources" dest="/etc/apt/sources.list.d/x.sources"
              mode="replace" backup="true"/>

<!-- 3) 引擎按发行版生成（换源） -->
<sudo-install kind="apt-mirror" mirror="ustc" dest="auto" when="os:ubuntu"/>
```

| 属性 | 用于 | 说明 |
|---|---|---|
| `src` | 全部 | 相对路径。有 `dest` 时是"要写的内容"，否则是"要跑的脚本" |
| `dest` | 系统文件 | 绝对路径；`auto` 只和 `kind` 一起用（由引擎算） |
| `kind` | 系统文件 | `apt-mirror` / `yum-mirror` / `distro-mirror` |
| `mirror` | 系统文件 | `auto`（**推荐**）/ `ustc`（没记录时的默认）/ `tuna` / `aliyun` / `huawei` / `netease` / `tencent`。<br>`auto` = 跟着 `install.sh` 第 0 步挑的那个镜像走（记在 `<state>/mirror.txt`）：有记录就**跳过换源**，没有才用 `ustc` —— 见 ADR-0032 |
| `mode` | 系统文件 | `replace`（备份后覆盖）/ `add`（不存在才建）/ `disable`（原文件改名禁用） |
| `backup` | 系统文件 | 默认 `replace` 时为 `true` |
| `marker` | 任务 | 幂等标记；成功后写 `$WTOOL_STATE/<id>/provisioned/<marker>` |
| `when` | 全部 | 逗号分隔的 AND：`os:ubuntu`、`!os:debian`、`arch:x86_64`、`env:WTOOL_HEAVY` |
| `desc` | 全部 | 人类可读说明 |

它由 **`wtool sudo-install`** 执行（`wtool sudo-bootstrap` 是所有项目跑一遍），
**不在 `wtool install` 里**。`/etc` 的改动备份三份（原文件旁边 / `/var/backups/wtool/` /
state），还原依据单独记在 `system.tsv`；apt 包按"跑前跑后的已装包差集"记账，
`wtool sudo-uninstall` 只卸这次装进来的。详见 `docs/spec.md` §11。

> 旧标签 `<system-file>` 和 `<provision>` 是它的前身（`runner=` 也删了，按扩展名判断）。
> 过渡期仍然认，但会警告。

---

## `<source>` —— 源码编译型项目

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `url` | ✅ | — | 上游仓库地址 |
| `ref` | ✅ | — | 固定到 tag/commit（**禁止浮动分支**） |
| `dir` | 否 | `$WTOOL_SRC/<id 末段>` | 源码树位置 |
| `branch` | 否 | `wsw` | 本地分支名 |
| `overlay` | 否 | `overlay` | 项目内要铺进源码树的目录 |
| `when` | 否 | — | 同 `<sudo-install>` |

执行：`clone/fetch` → `checkout --detach <ref>` → `checkout -B <branch>` → 铺 `overlay/*`
→ **提交到 `wsw` 分支**（这样工作区干净、`git diff` 有意义）。

---

## `<publish>` —— 怎么发布

**不写它 = `kind="source"`**：引擎打源码包 / 产物包，推到**本项目自己 remote** 的 release。
它只表达"文件表达不了的两件事"：推到**别的仓**、或者**根本不发**。

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `kind` | 否 | `source` | 只认 `source` / `none`（`none` = 不参与发布，第三方上游仓用这个） |
| `to` | 否 | 本项目 remote | 推到别的仓，写 `owner/repo` |
| `tag` | 否 | `snapshot-%Y-%m-%d` | release 的 tag（`%Y`/`%m`/`%d` 会替换成当天日期） |
| `asset` | 否 | — | 引擎只解析并透出（`publish-info` 读得到），当前发布流程不消费 |

子元素两个：

| 子元素 | 用途 |
|---|---|
| `<sub path= kind= to=/>` | 替**子树里没有 `wtool.xml` 的项目**表态（上游仓不能往里塞清单文件，只能从外面声明） |
| `<target os= version= codename= image=/>` | 目标系统矩阵；引擎只解析并透出（`publish-info` 读得到），发布流程不消费 |

**`kind="script"` 和 `script=` 已经取消**（ADR-023），现在写它们是**清单错误**，
`wtool validate` 会拒绝：

```xml
<!-- ✗ 报错：kind 只能是 source / none -->
<publish kind="script" script="scripts/publish.sh"/>
```

提示是"发布不再调项目脚本，构建逻辑放 `scripts/build.sh`" —— 发布全项目走同一条引擎的路：
`wtool pack-release`（`__output/` → `__release/`）+ `wtool publish-release`（`__release/` → GitHub）。

---

## `<include>`

| 属性 | 必填 | 说明 |
|---|---|---|
| `src` | ✅ | 相对本清单的相对路径，最多嵌套 8 层 |
| `optional` | 否 | 不存在时跳过 |

典型用途：`<include src="wtool.local.xml" optional="true"/>`，把机器本地差异放在一个**不入库**的文件里。

---

## 自定义元素

**没有这回事。** `<wtool>` 只认上面「标签总表」里列出的元素，其他一律报错
（避免拼写错误悄悄失效）—— **`x-` 前缀也不行**。

repo 的 manifest 用 `x-*` 把命名空间留给用户，`wtool.xml` **故意不跟**：
清单是引擎要逐条执行的动作表，一条没被理解的声明**静默丢掉**比报错危险得多。

报错本身就会指路（2026-09-28 起，BL-23）—— 它不再教人写 `x-*`（那正是它刚拒绝的东西，
照着改还是同一个错），而是给出真出路：

```
error: 未知元素 <x-note>（.../wtool.xml）；wtool.xml 没有自定义元素（x-* 也拒绝），
       机器本地差异请用 <include src="wtool.local.xml" optional="true"/>
```

机器本地差异就是那个 `wtool.local.xml`（不入库）。

---

## 校验清单（`wtool validate <项目>`）

| 检查 | 失败动作 |
|---|---|
| XML 可解析、根元素是 `<wtool>` | 拒绝 |
| `schema` 已知 | 拒绝 |
| `src` / `subproject` 相对、不含 `..`、存在、在本项目内 | 拒绝 |
| `home` 带 `~/`、不含 `..`、不逃出 `$HOME` | 拒绝 |
| `wtool` 写在 `~/.wtool/` 下面 | 拒绝 |
| 同一清单内 `home` 不重复 | 拒绝 |
| `home` 未被其他项目在 `registry.tsv` 里登记 | 拒绝（`--force` 降级为警告） |
| 落点在磁盘上不存在，或已是正确的软链 | 拒绝（`--force` 备份后接管） |
| 有 `build.sh` 就必须有非空的 `__output/` | 拒绝（`--force` 降级为警告） |
| `<publish kind=…>` 只能是 `source` / `none`；不能有 `script=` | 拒绝 |
| `<build kind=…>` 只能是 `local` / `docker`；`min-cores` / `min-mem` / `min-disk` 必须是正整数 | 拒绝 |
| 旧标签 | 警告（能装，但提醒改成新标签） |

---

## 完整示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" priority="20">

  <!-- 先于其它项目被 source -->
  <zshrc  src="env.zsh"  priority="20"/>
  <bashrc src="env.bash" priority="20"/>

  <!-- 把整个 zsh 配置目录接到 ~/.config/zsh（两跳：项目 → 影子 HOME → $HOME） -->
  <link home="~/.config/zsh"
        wtool="~/.wtool/.config/zsh"
        subproject="config"/>

  <!-- 单个文件也行 -->
  <link home="~/.zprofile"
        wtool="~/.wtool/.zprofile"
        subproject="zprofile"/>

  <!-- 机器本地覆盖，不入库 -->
  <include src="wtool.local.xml" optional="true"/>
</wtool>
```

要编译 / 要产出的项目，再加 `scripts/`（只有 `build.sh` 和 `install.sh` 两种，
**按需，别留空壳**）和 `__output/`（产物，`.gitignore` 里）。
下载和发布**不用脚本**：那是引擎的 `download-release` / `unpack-release`（取现成的包）和
`pack-release` / `publish-release`（打包上传）。
**文件存在即能力声明**：`scripts/` 下有没有那个文件，直接决定项目表里那一列亮不亮。

---

## 旧标签（过渡期，会警告）

| 旧 | 新 | 备注 |
|---|---|---|
| `<env src= shells=/>` | `<zshrc src=/>` / `<bashrc src=/>` | `shells=` 靠扩展名推断的那套删了 |
| `<link src= dest=/>` | `<link home= wtool= subproject=/>` | 没有中间那一跳；`force=` / `optional=` 一并删 |
| `<provision src= runner=/>` | `<sudo-install src=/>` | `runner=` 按扩展名判断 |
| `<system-file …/>` | `<sudo-install … dest=/etc/…/>` | 属性名不变 |
| `<publish kind="script" script=…/>` | **没有了** —— 报错 | 发布不再调项目脚本（ADR-023）。`<publish>` 本身**还在**，但只剩 `kind="source"`（默认）/ `kind="none"` / `to="owner/repo"`，见上文「`<publish>` —— 怎么发布」；构建逻辑归 `scripts/build.sh` |

兼容分支在**所有项目迁完之后**删除（见 `harness/architecture.md` §3 的改名对照）。

# 项目清单规范 `wtool.xml`

每个项目根目录放一份 `wtool.xml`。它是**纯声明**，不含逻辑。

## 最小可用清单

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/tmux" priority="50">

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
| `<link home= wtool= subproject= />` | 三段映射，见下 |
| `<link home= wtool= produced-by="install.sh"/>` | 同上，但中间那一跳由项目 `install.sh` 产出 |
| `<sudo-install src="provision/packages.yaml"/>` | 系统层：要跑的脚本 / playbook（要 sudo、要联网，不在 `install` 里跑） |
| `<sudo-install src="x.conf" dest="/etc/x.conf"/>` | 系统层：`/etc` 下的文件（可逆，备份/还原） |
| `<sudo-install kind="apt-mirror" mirror="ustc" dest="auto"/>` | 系统层：引擎按发行版生成内容（换源） |
| `<source url= ref= />` | 上游源码：clone → 固定 ref → 建本地分支 → 铺 overlay |
| `<include src= optional= />` | 拆清单 |
| `x-*` | 自定义（引擎不认别的未知标签） |

---

## `<wtool>` 根元素

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `schema` | ✅ | — | 清单格式版本。当前只支持 `1`；未知值会被拒绝 |
| `id` | 否 | 相对工作区的路径 | 项目身份。出现在 `~/.wtool/wtool-work-dir/links/<id>`、`$WTOOL_STATE/<id>/` 和 rc 块标记里，**改了必须重新 install** |
| `priority` | 否 | `100` | 越小越早加载；`<zshrc>`/`<bashrc>` 不写 `priority` 时继承它 |

`id` 允许带 `/`（例如 `terminal/tmux`），会形成嵌套目录，不要用 `..` 或绝对路径。

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
env.zsh  的内容 ──► ~/.wtool/.zshrc  ──┐
                                       ├── 用户 rc 里**一个** loader 块 source 它们
env.bash 的内容 ──► ~/.wtool/.bashrc ──┘   （全局的，不属于任何项目）
```

`eval "$(wtool doctor --quiet)"` 能把同一批变量直接灌进当前 shell。

---

## `<link>` —— 三段映射

三个属性**都必填**：

| 属性 | 说明 | 写什么 |
|---|---|---|
| `home` | `$HOME` 下的落点 | 写全，带 `~/` |
| `wtool` | `~/.wtool`（影子 HOME）下的落点 | 必填，即使它就是 `home` 的镜像路径也要写出来 —— 自解释，也允许例外 |
| `subproject` | 项目里的相对路径 | 内容从这儿来 |
| `produced-by` | 内容由谁产出 | 目前只认 `install.sh`（这时不写 `subproject`） |

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
| `mirror` | 系统文件 | `ustc`（默认）/ `tuna` / `aliyun` |
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

## `<include>`

| 属性 | 必填 | 说明 |
|---|---|---|
| `src` | ✅ | 相对本清单的相对路径，最多嵌套 8 层 |
| `optional` | 否 | 不存在时跳过 |

典型用途：`<include src="wtool.local.xml" optional="true"/>`，把机器本地差异放在一个**不入库**的文件里。

---

## 自定义元素

repo 的 manifest 用 `x-*` 保留给用户。这里同样：**自定义元素请用 `x-` 前缀**；其他未知元素一律报错（避免拼写错误悄悄失效）。

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
| 有 `build.sh`/`download.sh` 就必须有非空的 `release/` | 拒绝（`--force` 降级为警告） |
| 旧标签 | 警告（能装，但提醒改成新标签） |

---

## 完整示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="shell/zsh" priority="20">

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

要编译 / 要下载产物的项目，再加 `scripts/`（`build.sh` / `download.sh` /
`install.sh` / `publish.sh`，**按需，别留空壳**）和 `release/`（产物，`.gitignore` 里）。
**文件存在即能力声明**：`scripts/` 下有没有那个文件，直接决定项目表里那一列亮不亮。

---

## 旧标签（过渡期，会警告）

| 旧 | 新 | 备注 |
|---|---|---|
| `<env src= shells=/>` | `<zshrc src=/>` / `<bashrc src=/>` | `shells=` 靠扩展名推断的那套删了 |
| `<link src= dest=/>` | `<link home= wtool= subproject=/>` | 没有中间那一跳；`force=` / `optional=` 一并删 |
| `<provision src= runner=/>` | `<sudo-install src=/>` | `runner=` 按扩展名判断 |
| `<system-file …/>` | `<sudo-install … dest=/etc/…/>` | 属性名不变 |
| `<publish kind= …/>`（含 `<sub>` / `<target>`） | **整个删掉** | 能力由文件声明：有 `scripts/publish.sh` 就是脚本型发布；`pack-release` 负责打包 |

兼容分支在**所有项目迁完之后**删除（见 `harness/notes/00-architecture.md` §3 的改名对照）。

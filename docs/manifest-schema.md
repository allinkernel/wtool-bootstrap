# 项目清单规范 `wtool.xml`

每个项目根目录放一份 `wtool.xml`。它是**纯声明**，不含逻辑。

## 最小可用清单

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="terminal/tmux" priority="50">
  <env src="env.zsh" shells="zsh"/>
  <link src="tmux.conf" dest=".tmux.conf"/>
</wtool>
```

---

## `<wtool>` 根元素

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `schema` | ✅ | — | 清单格式版本。当前只支持 `1`；未知值会被拒绝 |
| `id` | 否 | 项目目录名 | 项目身份。出现在 `~/.wtool/links/<id>`、`$WTOOL_STATE/<id>/` 和 rc 块标记里，**改了必须重新 install** |
| `priority` | 否 | `100` | 未显式声明 `priority` 的 `<env>` 继承它 |

`id` 允许带 `/`（例如 `terminal/tmux`），会形成嵌套目录，不要用 `..` 或绝对路径。

---

## `<env>` —— 要被 source 的部分

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src` | ✅ | — | 相对项目根的文件路径 |
| `shells` | 否 | 按扩展名推断 | 逗号分隔，取值 `zsh` / `bash` / `sh` |
| `priority` | 否 | 继承根元素 | 决定 rc 块顺序，数值小的在前 |
| `optional` | 否 | `false` | 文件不存在时只警告、不报错 |

扩展名推断规则：

| 文件名 | 推断出的 shells | 会注入哪些 rc |
|---|---|---|
| `env.zsh` | `zsh` | `~/.zshrc` |
| `env.bash` | `bash` | `~/.bashrc` |
| `env.sh` | `zsh,bash` | 两个都注入 |

> `sh` 只是"方言"标记：POSIX 没有用户级 rc 文件，所以它不会单独产生注入。

### env 文件的标准输入

加载器在 source 之前导出以下变量，**env 文件因此不需要任何"猜自己路径"的技巧**：

| 变量 | 值 |
|---|---|
| `WTOOL_PROJECT_ID` | 例如 `terminal/tmux` |
| `WTOOL_PROJECT_DIR` | `$HOME/.wtool/links/<id>`（稳定中转链接） |
| `WTOOL_PROJECT_ROOT` | 仓库的真实路径 |

约束：env 文件**只做导出/定义**，不要有副作用（不写文件、不启动进程、不打印）。它可能被 source 多次。

---

## `<link>` —— 要被软链接的部分

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src` | ✅ | — | 相对项目根；必须存在、必须在本项目内 |
| `dest` | ✅ | — | **相对 `$HOME`**；不允许绝对路径、不允许 `..` |
| `force` | 否 | `false` | 该条允许覆盖已存在的非软链（会先备份） |
| `optional` | 否 | `false` | `src` 不存在时跳过 |

链接的最终形态是两级：

```
$HOME/.tmux.conf  ->  $HOME/.wtool/links/terminal/tmux/tmux.conf  ->  仓库真实文件
                       └── 稳定中转链接，指向仓库根
```

所以**仓库搬家不影响任何链接和 rc 块**，重跑 install 即可。

### 声明链接 vs 稳定地址

`<link>` 只声明"应用去找的"链接（如 `~/.tmux.conf`）。
`~/.wtool/links/<id>` 是引擎 install 时**自动创建**、指向整个项目根的"稳定地址"，**不要**在清单里声明。

**项目内部文件互相引用时用稳定地址**，例如 `tmux.conf` 里引用 `bin/` 脚本：

```
#($HOME/.wtool/links/terminal/tmux/bin/mem.sh)
```

不要用自定义 env 变量（如 `$WTOOL_TMUX_DIR`）——tmux 的 `#()` 执行时 `$HOME` 必然存在，
而自定义变量只有启动 tmux server 的那个 shell 里有。详见 `docs/spec.md` §2。

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

## 校验清单（`wtool.sh validate <项目>`）

| 检查 | 失败动作 |
|---|---|
| XML 可解析、根元素是 `<wtool>` | 拒绝 |
| `schema` 已知 | 拒绝 |
| `src` 相对、不含 `..`、存在、在本项目内 | 拒绝 |
| `dest` 相对 `$HOME`、不含 `..`、不逃出 `$HOME` | 拒绝 |
| 同一清单内 `dest` 不重复 | 拒绝 |
| `dest` 未被其他项目在 `registry.tsv` 里登记 | 拒绝（`--force` 降级为警告） |
| `dest` 在磁盘上不存在，或已是正确的软链 | 拒绝（`--force` 备份后接管） |
| `<env>` 的 shell 已知 | 拒绝 |

---

## 完整示例

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="shell/zsh" priority="10">

  <!-- 先于其它项目被 source -->
  <env src="env.zsh" shells="zsh" priority="10"/>

  <!-- 把整个 zsh 配置目录链到 ~/.config/zsh -->
  <link src="config" dest=".config/zsh"/>

  <!-- 可选：某些机器上没有这个文件 -->
  <link src="extra.zsh" dest=".config/zsh/extra.zsh" optional="true"/>

  <!-- 机器本地覆盖，不入库 -->
  <include src="wtool.local.xml" optional="true"/>
</wtool>
```

---

## `<system-file>` —— 写 `$HOME` 之外的系统文件（换源等）

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `dest` | ✅ | — | 绝对路径；与 `kind` 搭配时写 `auto` 由引擎决定 |
| `src` | 否* | — | 项目内相对路径，作为文件内容 |
| `kind` | 否* | — | `apt-mirror` / `yum-mirror` / `distro-mirror`，引擎按 `/etc/os-release` 生成 |
| `mirror` | 否 | `ustc` | `ustc` / `tuna` / `aliyun` |
| `mode` | 否 | `replace` | `replace` / `add` / `disable` |
| `backup` | 否 | `replace` 时为 `true` | 是否备份原文件 |
| `desc` | 否 | — | 说明（打印用） |

\* `mode="disable"` 时两者都可省略。

```xml
<!-- 换源：自动识别 ubuntu + codename，生成 deb822 -->
<system-file kind="apt-mirror" mirror="ustc" dest="auto"
             mode="replace" backup="true" when="os:ubuntu"
             desc="apt 源换成 USTC 镜像"/>

<!-- 或者用自己写的文件 -->
<system-file src="my.sources" dest="/etc/apt/sources.list.d/my.sources"
             mode="replace" backup="true"/>

<!-- 把官方源改名禁用 -->
<system-file dest="/etc/apt/sources.list.d/ubuntu.sources" mode="disable"/>
```

---

## `<source>` —— 源码编译型项目

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `url` | ✅ | — | 上游仓库地址 |
| `ref` | ✅ | — | 固定 tag/commit |
| `dir` | 否 | `$WTOOL_SRC/<id 末段>` | 源码树位置 |
| `branch` | 否 | `wsw` | 本地分支名 |
| `overlay` | 否 | `overlay` | 铺进源码树的目录 |

引擎会：clone/fetch → 切到 `ref` → 建/重置本地 `wsw` 分支 → 把 `overlay/*` 铺进去
→ 提交到 `wsw` 分支。你的 `wsw.sh` 就放在 `overlay/` 里。

---

## `<provision>` —— 任务

| 属性 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `src` | ✅ | — | 脚本/playbook（先找源码树，再找项目根） |
| `runner` | 否 | 按扩展名 | `ansible` / `shell` |
| `marker` | 否 | — | 幂等标记；成功后重复执行会跳过 |
| `when` | 否 | — | `os:ubuntu,arch:x86_64`（逗号 = AND） |
| `desc` | 否 | — | 说明 |

完整例子（编译型项目）：

```xml
<wtool schema="1" id="build/nvim" priority="70">
  <source url="https://github.com/neovim/neovim.git" ref="v0.10.4"
          dir="$WTOOL_SRC/nvim" branch="wsw" overlay="overlay"/>
  <provision src="wsw.sh" marker="nvim-{ref}" desc="编译安装 neovim 到 ~/.wtool/usr"/>
</wtool>
```

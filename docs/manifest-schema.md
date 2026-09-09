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

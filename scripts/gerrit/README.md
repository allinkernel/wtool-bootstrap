# gerrit（docker24）——本工作区的代码检视闸门

这里的东西不是给用户装机的，是**给这个工作区的开发流程**用的：
一台跑在 docker 里的 Gerrit（它的 web UI 就叫 PolyGerrit），
用来保证"凡是进 main 的改动，人都看过并且 +2 过"。

```
你要提交的：  ds_dev 分支  --git push polygerrit HEAD:refs/for/main-->  Gerrit change
                                                                          |
                                                    你在网页上 Code-Review +2
                                                                          |
                                                       submit（合并进 Gerrit 的 main）
                                                                          |
                                            再把 Gerrit 的 main 推回 GitHub 的 main
```

* **Gerrit 的 main 是"受检视的镜像"**，GitHub 的 main 依旧是公开主线；
  两边内容一致，但只有经过 +2 的提交才会从 Gerrit 流向 GitHub。
* 每个仓库里多了一条 remote `polygerrit`；原来的 `origin`/`github` 一个字没动。

## 起停

```sh
sh up.sh                  # 起容器（幂等；不在就 run，在就 start）
sh up.sh --recreate       # 删了重建（改了镜像/端口/挂载时用；数据在命名卷里，不丢）
docker stop docker24      # 停
docker logs -f docker24   # 看日志
```

* 镜像：`gerritcodereview/gerrit:3.14.3-ubuntu24`（官方镜像，自带 JDK21）
* 端口：**只绑 127.0.0.1** —— `http://127.0.0.1:8080/`（网页）、`29418`（ssh）
* 卷：`docker24-{git,etc,db,index,cache}` —— 站点数据。**别删这几个卷**，删了账号和仓库就没了
* 工作区以 `/wtool:ro` 挂进容器（只读），方便在容器里对着清单做导入

> 为什么单开这些卷：镜像自己声明了 `VOLUME /var/gerrit/{git,etc,db,index,cache}`。
> 不显式给命名卷，docker 会替你建匿名卷——下次删容器时数据就跟着找不着了，
> 而 `docker run --rm` 的临时容器看到的又是一套空站点，非常容易看走眼。

## 第一次（或者重装后）

```sh
sh bootstrap.sh           # 账号 + 权限 + 密钥；幂等
sh import.sh              # 把工作区里每个项目原样搬进 gerrit（建项目 + 推 main）
sh local-setup.sh         # 每个仓库加 polygerrit remote + 建 ds_dev 分支 + 装 commit-msg hook
```

三个脚本都可以 `--dry-run` / `--check` 先看一眼。它们做的事：

| 脚本 | 干什么 | 幂等性靠什么 |
|---|---|---|
| `bootstrap.sh` | 造两把 key、建 `admin`/`mindul`/`dsh-agent` 账号、改 All-Projects 的 ACL | 先查再建；admin key 只在 ssh 不通时才写 NoteDb |
| `import.sh` | 每个项目 `create-project` + 把当前 HEAD 推到 `refs/heads/main` | `ls-projects` / `ls-projects --show-branch` 先查 |
| `local-setup.sh` | 加 remote、建分支、装 hook | `git remote get-url` / `show-ref` 先查 |

## 账号与权限（这是"闸门"的关键）

| 账号 | 是谁 | 能干什么 |
|---|---|---|
| `admin` | 引导账号（Gerrit init 建的） | 管服务器、导入历史。日常**不用**它 |
| `mindul`（`WTOOL_GERRIT_REVIEWER`） | **你** | Administrators：能 +2、能 submit。用 `http://127.0.0.1:8080/login/?user_name=mindul` 登录 |
| `dsh-agent`（`WTOOL_GERRIT_AGENT`） | AI 助手 | 只能推 `refs/for/*`。**推不了 `refs/heads/*`** |

闸门不是"submit 权限"，是 **Code-Review +2 这个 submit-requirement**：

```
[submit-requirement "Code-Review"]
    submittableIf = label:Code-Review=MAX AND -label:Code-Review=MIN
```

默认 ACL 里只有 Administrators 能投 +2，`dsh-agent` 只能投 -1..+1。
所以**没有你的 +2，谁都 submit 不了**（包括助手）；
`submit` 权限放开给 Registered Users 只是为了让你 +2 之后助手能直接把它并掉，
不是因为助手的权限更大了。

`All-Projects` 被改的只有两处：`refs/heads/*` 上
`push = Administrators`（导入历史用；和默认 ACL 的差别就是这一条）
和 `submit = Registered Users`。ACL 改动用的是 admin 的 http 密码
（`curl -u admin:<密码>`），密码在 `.gerrit/admin-http-password`。

## 日常怎么用

```sh
cd <某个项目>
git push polygerrit HEAD:refs/for/main      # 送检，输出里就有 change 链接
gchk <change>                               # 看 +2 了没、merged 了没
ggcp <change> [patchset]                    # 把某个 change 的某个 patchset 抓回本地
```

`local-setup.sh` 装的 `commit-msg` hook 会往提交信息里加 `Change-Id`——
**同一个 Change-Id 的多次 push 是同一个 change 的不同 patchset**。

## 坑（都踩过）

1. **镜像的匿名卷**：见上面"为什么单开这些卷"。
2. **`ssh` 会吃掉循环的 stdin**：`ls-projects | while read p; do ssh ...; done`
   读两行就停。脚本里改成 fd 3 喂循环（`while read ... <&3; done 3< file`）。
3. **`docker inspect` 在容器不存在时会往 stdout 吐空行**：
   `docker inspect ... || echo absent` 拿到的是 `"\nabsent"`，`case` 匹配不上。
   `lib.sh` 里已经把状态归一化过。
4. **JGit 不收零填充 filemode**：`shell/oh-my-zsh` 的历史里有老 tree
   写成 `040000`（正常是 `40000`），Gerrit 直接拒收整个 push。
   这类上游 fork 没必要进检视流程，`import.sh` 明确跳过并说明原因。
5. **`ssh <gerrit> gerrit query` 的 stderr 不能混进 JSON**：
   `known_hosts` 写不进去时 ssh 会抱怨一句，`$(... 2>&1)` 就把 JSON 搅脏了。
   `env.zsh` 里加了 `LogLevel=ERROR` 并把 stderr 单独落文件。
6. **ssh 的用户名不是随便写的**：Gerrit 按"会话里的用户名"找账号、
   再核对公钥——`ssh -i dsh-agent_key mindul@host` 会被拒。
   所以 remote URL 里写了 `dsh-agent@`。

## 相关文件

| 路径 | 说明 |
|---|---|
| `.gerrit/keys/` | 两把私钥（admin / agent），600 权限，**不要提交** |
| `.gerrit/client.conf` | `ggcp`/`gchk`/`gq` 读的服务器地址（host/port/user/sshkey） |
| `.gerrit/admin-http-password` | admin 的 REST 密码（改 ACL 用） |
| `tools/repo/env.zsh` | `ggcp`/`gchk`/`gq`/`gpush` 的实现（另一个仓库） |

## 助手的 shell 里怎么用这些命令

`ggcp`/`gchk` 是 `tools/repo/env.zsh` 里的 zsh 函数，正常靠 `~/.zshrc` 的
wtool 块加载。助手跑在受限沙箱里（写不了 `$HOME`），所以它直接指到仓库：

```sh
WTOOL_PROJECT_DIR=/home/mindul/self/wtool/tools/repo \
  zsh -c 'source $WTOOL_PROJECT_DIR/env.zsh; cd /home/mindul/self/wtool; ggcp 24 1'
```

你自己装了 wtool 之后（`./install.sh` + `wtool bootstrap`）直接在 shell 里敲就行。

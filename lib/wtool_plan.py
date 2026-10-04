#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wtool 规划器 —— 纯逻辑层。

职责边界（见 docs/spec.md §3）：
  * 只读输入：项目清单 wtool.xml、目标 rc 文件、状态目录里的 registry/journal
  * 只写 scratch 目录（由 --scratch 指定），绝不写 $HOME
  * 对 $HOME 的一切修改都由 lib/wtool_fs.sh 执行

输出：
  <scratch>/plan.tsv    给 sh 执行的动作表（TSV，字段见下）
  <scratch>/rc.<n>      rc 文件的最终内容
  stdout                人类可读摘要

plan.tsv 列（制表符分隔，无表头）：
  action  kind  dest  source  sha256  extra
    action  link | rc
    kind    dir | file
    dest    绝对路径（要创建/修改的东西）
    source  link -> 软链目标；rc -> scratch 里的新内容文件
    sha256  rc 新内容的 sha256（link 行留空）
    extra   rc 行：被替换掉的旧 block 的 sha256，没有则 '-'
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ENGINE_VERSION = "1.0.0"
SCHEMA_SUPPORTED = (1,)
DEFAULT_PRIORITY = 100
# <build kind=...>：构建方式（ADR-025）。local = 本地直接编、产物天然跨发行版；
# docker = 每个发行版一个容器、分层构建。默认 local（不写就是本地编）。
BUILD_KINDS = ("local", "docker")

# ---------------------------------------------------------------------------
# 引擎自用目录：~/.wtool/wtool-work-dir/
#
# ~/.wtool/ 是影子 $HOME：里面只允许出现"真 $HOME 里也会有的路径"
# （~/.tmux.conf ↔ ~/.wtool/.tmux.conf，~/usr ↔ ~/.wtool/usr）。
# 而"中转软链 <id> -> 项目目录"是**引擎自己造的东西**，$HOME 里没有对应物，
# 所以它不能直接躺在 ~/.wtool/links/<id>（用户 2026-09-23 拍板）。
# 引擎自用的一切都关进这一格 —— 它是影子 $HOME 下唯一一个故意不像 $HOME 的目录。
WORK_DIR_NAME = "wtool-work-dir"


def links_dir_for(home, project_id):
    """中转软链在磁盘上的真实路径。"""
    return os.path.join(home, ".wtool", WORK_DIR_NAME, "links", project_id)


def links_dir_shell(project_id):
    """写进 env 块的写法：$HOME 留到 source 时再展开（仓库搬家不用改块）。"""
    return '"$HOME/.wtool/%s/links/%s"' % (WORK_DIR_NAME, project_id)


def project_id_of(project_root, root=None):
    """项目身份 = 它**相对工作区根的路径**（用户 2026-10-04 拍板：干掉项目 id）。

    以前 `wtool.xml` 可以用 `id="..."` 覆盖身份，于是"改了目录忘了改 id"
    就会让状态目录 / 中转软链 / env 块名三处和路径对不上（看板会说"没装"，
    而其实装了）。现在身份**只有一个来源** —— 路径。

    工作区**外面**的项目（`wtool install /abs/path`，测试里很常见）相对路径
    会以 `..` 开头，那不是合法身份，退回目录名 —— 和以前 `WTOOL_ROOT` 没导出
    时的兜底行为一致。
    """
    p = os.path.abspath(project_root)
    ws = os.path.abspath(root or os.environ.get("WTOOL_ROOT") or os.path.dirname(p))
    pid = os.path.relpath(p, ws)
    if pid in (".", "/") or pid == ".." or pid.startswith(".." + os.sep):
        return os.path.basename(p)
    return pid


def cmd_project_id(project, root=None):
    """打印项目身份（= 它相对工作区根的路径）。工作区外面 → 退出码 1。

    和 `project_id_of` 的差别：那个是"引擎内部算身份"（工作区外面退回目录名，
    因为 `install /abs/path` 这条路一直支持）；这个是**给人看的**（`init` 用它），
    所以工作区外面**直接失败**，不悄悄给一个目录名当身份。
    """
    p = os.path.abspath(project)
    ws = os.path.abspath(root or os.environ.get("WTOOL_ROOT") or os.path.dirname(p))
    rel = os.path.relpath(p, ws)
    if rel in (".", "/") or rel == ".." or rel.startswith(".." + os.sep):
        sys.stderr.write("项目不在工作区里: %s（工作区 %s）\n" % (p, ws))
        return 1
    print(rel)
    return 0


# 影子 HOME 的根（~/.wtool）；$HOME 里的路径在它下面同名
SHADOW_ROOT_NAME = ".wtool"
# release.zip 里带的"声明面"：只下 release.zip 的机器也要能 wtool install
DECLARE_FILES = ("wtool.xml", "env.zsh", "env.bash")
# 分卷大小：网络不稳，卷要小（见 harness/architecture.md §5）
DEFAULT_VOLUME_SIZE = "32M"

# 发布只有引擎一条路（ADR-023）：pack-release 打包 → publish-release 上传。
# `<publish>` 标签仍然有用：`to=` 推到别的仓、`kind="none"` 表示不发布。
DEFAULT_PUBLISH_TAG = "snapshot-%Y-%m-%d"
PUBLISH_KINDS = ("source", "none")
# source 包的第一层目录名固定，跟本机工作区目录叫什么无关
PUBLISH_ARCHIVE_PREFIX = "wtool"

# 哪些 shell 有"用户级 rc 文件"可以注入
RC_FILE_BY_SHELL = {"zsh": ".zshrc", "bash": ".bashrc"}
RC_CAPABLE_SHELLS = tuple(RC_FILE_BY_SHELL)
# env 文件扩展名 -> 默认适用 shell
SHELLS_BY_EXT = {"zsh": ("zsh",), "bash": ("bash",), "sh": ("zsh", "bash")}

BLOCK_BEGIN_RE = re.compile(r"^# >>> wtool:(\S+) (.*) >>>\s*$")
BLOCK_END_RE = re.compile(r"^# <<< wtool:(\S+) <<<\s*$")
ATTR_RE = re.compile(r"([A-Za-z_][\w-]*)=(\S+)")


class PlanError(Exception):
    """规划阶段的致命错误：调用方应拒绝执行并原样打印。"""


# --------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------
def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def is_safe_rel(path):
    """相对路径、不含 ..、不是绝对路径、非空。"""
    if not path or os.path.isabs(path):
        return False
    parts = path.replace("\\", "/").split("/")
    return not any(p in ("..", "") for p in parts)


def is_under(path, base):
    path = os.path.abspath(path)
    base = os.path.abspath(base)
    return path == base or path.startswith(base.rstrip("/") + "/")


# --------------------------------------------------------------------------
# 清单解析
# --------------------------------------------------------------------------
class Entry(object):
    def __init__(self, kind, src, **kw):
        self.kind = kind
        self.src = src
        self.__dict__.update(kw)

    def __repr__(self):
        return "<Entry %s %s>" % (self.kind, self.src)


def parse_manifest(path, project_root, errors, warnings=None):
    """解析 wtool.xml（支持 include）。返回 (meta, entries)。

    warnings 传了就把"旧写法该改了"这类提示记进去；没传就丢掉
    （表格扫描、publish 解析这些只关心结果的调用方不需要它们）。
    """
    if warnings is None:
        warnings = []
    text = read_text(path)
    if text is None:
        errors.append("清单不存在: %s" % path)
        return None, []

    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        errors.append("清单 XML 解析失败: %s: %s" % (path, exc))
        return None, []

    if root.tag != "wtool":
        errors.append("清单根元素必须是 <wtool>，实际是 <%s>" % root.tag)
        return None, []

    raw_schema = root.get("schema")
    if raw_schema is None:
        errors.append("清单缺少 schema 属性（当前支持: %s）"
                      % ",".join(str(s) for s in SCHEMA_SUPPORTED))
        return None, []
    try:
        schema = int(raw_schema)
    except ValueError:
        errors.append("schema 必须是整数，实际是 %r" % raw_schema)
        return None, []
    if schema not in SCHEMA_SUPPORTED:
        errors.append("不支持的 schema=%d（本引擎支持: %s），请升级 wtool-bootstrap"
                      % (schema, ",".join(str(s) for s in SCHEMA_SUPPORTED)))
        return None, []

    # 项目身份 = 它相对工作区根的路径（用户 2026-10-04 拍板）。
    #
    # `id=` 属性已经取消，而且这里**硬报错**、不留兼容窗口：它和路径重复，
    # 一旦写得不等于路径，"改了目录忘了改 id"就会让状态目录 / 中转软链 /
    # env 块名三处对不上 —— 表现是"装完了但看板说没装"，这种半装状态最难查。
    # 与其给一个每次都要判断"信 id 还是信路径"的过渡期，不如现在就说清楚。
    raw_id = root.get("id")
    if raw_id is not None:
        errors.append(
            "wtool.xml 里的 id=%r 已经取消：项目身份就是它相对工作区根的路径。"
            "删掉这个属性即可（%s）" % (raw_id, path))
        return None, []

    default_prio = _int_attr(root, "priority", DEFAULT_PRIORITY, errors, "wtool")
    meta = {
        "schema": schema,
        # 身份不在这里 —— 它由 project_id_of(路径) 现算，见那个函数。
        "priority": default_prio,
        "manifest_path": path,
        "manifest_sha": sha256_text(text),
        # 没写 <publish> 就等于 kind="source"：打包源码推到本项目自己 origin 的 release。
        # _declared 记"老清单显式写过 <publish>"，用来在能力判定里区分
        # "声明了不发布" 和 "压根没声明"。
        "publish": {"kind": "source", "script": "", "tag": DEFAULT_PUBLISH_TAG,
                    "asset": "", "subs": [], "targets": [], "_declared": False},
        # <build kind=...>：**只有 kind 进 XML**，targets / 层清单是项目数据（ADR-025）。
        # 三个 min-* 是"这台机器够不够"的门槛，引擎有默认值兜底（wtool.sh 的
        # wt_default_min_*），所以这里 None = 没声明。
        "build": {"kind": "local", "min_cores": None, "min_mem_gb": None,
                  "min_disk_gb": None, "_declared": False},
    }

    entries = []
    _parse_children(root, project_root, path, meta, entries, errors, depth=0,
                    warnings=warnings)
    return meta, entries


def _parse_publish(node, meta, manifest_path, errors):
    """<publish>：项目声明自己怎么发布。

    kind="source"（默认）  引擎打源码包 + 产物包 → 推到本项目 origin 的 release
    kind="none"            不参与发布（第三方上游仓等）

    ⚠️ 2026-09-28（ADR-023）：`kind="script"` 与 `script=` 删除 ——
    发布只有引擎一条路，项目特有的逻辑归 `scripts/build.sh`。
    """
    kind = (node.get("kind") or "source").strip()
    if kind not in PUBLISH_KINDS:
        errors.append("<publish kind=%r> 只能是 %s（%s）"
                      % (kind, "/".join(PUBLISH_KINDS), manifest_path))
        return
    if node.get("script"):
        errors.append("<publish script=%r> 已经取消（ADR-023）："
                      "发布不再调项目脚本，构建逻辑放 scripts/build.sh（%s）"
                      % (node.get("script"), manifest_path))
        return

    info = {
        "kind": kind,
        "script": "",
        "tag": (node.get("tag") or DEFAULT_PUBLISH_TAG).strip(),
        # 发布目标仓：默认取项目 origin；写 to= 可以推到别的仓
        "to": (node.get("to") or "").strip(),
        "asset": (node.get("asset") or "").strip(),
        "subs": [],
        "targets": [],
        "_declared": True,
    }

    for child in node:
        if child.tag == "sub":
            # 替子树里"没有 wtool.xml 的项目"表态。
            # 上游仓（neovim/neovim）不能往里塞 wtool.xml，只能从外面声明。
            path = (child.get("path") or "").strip()
            sub_kind = (child.get("kind") or "source").strip()
            if not path or not is_safe_rel(path):
                errors.append("<sub path=%r> 必须是相对路径" % path)
                continue
            if sub_kind not in PUBLISH_KINDS:
                errors.append("<sub kind=%r> 只能是 %s" % (sub_kind,
                                                          "/".join(PUBLISH_KINDS)))
                continue
            info["subs"].append({"path": path.rstrip("/"), "kind": sub_kind,
                                 "to": (child.get("to") or "").strip()})
        elif child.tag == "target":
            os_id = (child.get("os") or "").strip()
            version = (child.get("version") or "").strip()
            if not os_id or not version:
                errors.append("<target> 需要 os= 和 version=（%s）" % manifest_path)
                continue
            info["targets"].append({"os": os_id, "version": version,
                                    "codename": (child.get("codename") or "").strip(),
                                    "image": (child.get("image") or "").strip()})
        else:
            errors.append("<publish> 里不认识 <%s>，只支持 <sub>/<target>（%s）"
                          % (child.tag, manifest_path))

    meta["publish"] = info


def _parse_build(child, meta, manifest_path, errors):
    """`<build kind="local|docker" min-cores= min-mem= min-disk=/>`（ADR-025）。

    `kind` 决定 `__output/` 的形状：`local` 没有 `<os>_<ver>/` 那一层，`docker` 有。
    形状**由声明唯一确定**，引擎不再嗅探（ADR-025 第 2 条）。

    三个 `min-*` 是"这台机器够不够跑这个构建"的门槛（引擎侧有默认值），
    跟 `kind` 写在同一个标签里是因为它们描述的是同一件事：**这个构建要什么**。
    """
    info = meta["build"]
    info["_declared"] = True

    kind = (child.get("kind") or "local").strip()
    if kind not in BUILD_KINDS:
        errors.append("<build kind=%r> 只能是 %s（%s）"
                      % (child.get("kind"), " / ".join(BUILD_KINDS), manifest_path))
    else:
        info["kind"] = kind

    for attr, key in (("min-cores", "min_cores"), ("min-mem", "min_mem_gb"),
                      ("min-disk", "min_disk_gb")):
        if child.get(attr) is None:
            continue
        val = _int_attr(child, attr, None, errors, "<build>")
        if val is None:
            info[key] = None
        elif val <= 0:
            errors.append("<build %s=%r> 必须是正整数（%s）" % (attr, child.get(attr),
                                                          manifest_path))
        else:
            info[key] = val


def effective_publish(path, pub):
    """发布方式的最终判定。

    **发布只有引擎一条路**（ADR-023）：`pack-release` 打包 → `publish-release` 上传。
    2026-09-28 起 **`scripts/publish.sh` 不再被认**（脚本型发布退休）——
    项目特有的构建逻辑归 `scripts/build.sh`，打包上传归引擎。

    `<publish>` 标签仍然有用，因为它能表达两件文件表达不了的事：
    推到别的仓（`to=`）和"不发布"（`kind="none"`，第三方上游仓要它）。
    """
    out = dict(pub or {})
    for key, default in (("kind", "source"), ("script", ""),
                         ("tag", DEFAULT_PUBLISH_TAG), ("to", ""),
                         ("asset", ""), ("subs", []), ("targets", [])):
        out.setdefault(key, default)
    return out


def _parse_children(node, project_root, manifest_path, meta, entries, errors, depth,
                    warnings=None):
    if warnings is None:
        warnings = []
    if depth > 8:
        errors.append("include 嵌套超过 8 层，疑似循环: %s" % manifest_path)
        return

    def _legacy(tag, new_hint):
        warnings.append("<%s> 是旧写法，请改成 %s（%s）" % (tag, new_hint, manifest_path))

    for child in node:
        tag = child.tag

        # ---------------------------------------------------------------- env
        if tag in ("zshrc", "bashrc"):
            # <zshrc src="env.zsh"/>：这个文件的内容进 ~/.wtool/.zshrc
            shell = tag[:-2]                       # zshrc -> zsh, bashrc -> bash
            src = child.get("src")
            if not src:
                errors.append("<%s> 缺少 src（%s）" % (tag, manifest_path))
                continue
            if not is_safe_rel(src):
                errors.append("<%s src=%r> 必须是不含 .. 的相对路径" % (tag, src))
                continue
            prio = _int_attr(child, "priority", meta["priority"], errors,
                             "%s %s" % (tag, src))
            entries.append(Entry("env", src, shells=(shell,), priority=prio,
                                 optional=_bool_attr(child, "optional"),
                                 manifest=manifest_path))

        elif tag == "env":
            # 旧写法：<env src="env.zsh" shells="zsh"/>（shells 靠扩展名推断）
            _legacy("env", '<zshrc src="env.zsh"/> / <bashrc src="env.bash"/>')
            src = child.get("src")
            if not src:
                errors.append("<env> 缺少 src（%s）" % manifest_path)
                continue
            shells_raw = child.get("shells")
            if shells_raw:
                shells = tuple(s.strip() for s in shells_raw.split(",") if s.strip())
                unknown = [s for s in shells if s not in SHELLS_BY_EXT]
                if unknown:
                    errors.append("<env src=%r> 含未知 shell: %s（已知: %s）"
                                  % (src, ",".join(unknown), ",".join(SHELLS_BY_EXT)))
                    continue
            else:
                ext = src.rsplit(".", 1)[-1] if "." in src else "sh"
                shells = SHELLS_BY_EXT.get(ext)
                if shells is None:
                    errors.append("<env src=%r> 无法从扩展名推断 shell，请显式写 shells="
                                  % src)
                    continue
            prio = _int_attr(child, "priority", meta["priority"], errors,
                             "env %s" % src)
            entries.append(Entry("env", src, shells=shells, priority=prio,
                                 optional=_bool_attr(child, "optional"),
                                 manifest=manifest_path))

        # --------------------------------------------------------------- link
        elif tag == "link":
            entry = _parse_link(child, errors, warnings, manifest_path)
            if entry is not None:
                entries.append(entry)

        # -------------------------------------------------------- sudo-install
        elif tag == "sudo-install":
            for entry in _parse_sudo_install(child, errors, warnings,
                                             manifest_path):
                entries.append(entry)

        elif tag == "system-file":
            # 旧写法：换源等系统文件。已经并进 <sudo-install>
            _legacy("system-file", '<sudo-install src=... dest=/etc/... mode=.../>')
            entry = _parse_system_file(child, errors, manifest_path)
            if entry is not None:
                entries.append(entry)

        elif tag == "source":
            # 上游源码：clone → 固定 ref → 建/重置本地分支 → 铺 overlay
            url = child.get("url")
            ref = child.get("ref")
            if not url:
                errors.append("<source> 需要 url（%s）" % manifest_path)
                continue
            if not ref:
                errors.append("<source> 需要 ref（必须固定到 tag/commit，禁止浮动分支）")
                continue
            entries.append(Entry("source", url,
                                 ref=ref,
                                 dir=child.get("dir") or "",
                                 branch=child.get("branch") or "wsw",
                                 overlay=child.get("overlay") or "overlay",
                                 when=child.get("when") or "",
                                 manifest=manifest_path))

        elif tag == "provision":
            # 旧写法：已改名为 <sudo-install src=.../>
            _legacy("provision", '<sudo-install src="provision/packages.sh"/>')
            src = child.get("src")
            if not src:
                errors.append("<provision> 需要 src（%s）" % manifest_path)
                continue
            runner = child.get("runner")
            if not runner:
                runner = "ansible" if src.endswith((".yaml", ".yml")) else "shell"
            if runner not in ("ansible", "shell"):
                errors.append("<provision> runner 只能是 ansible/shell，实际 %r" % runner)
                continue
            entries.append(Entry("task", src, runner=runner,
                                 marker=child.get("marker") or "",
                                 when=child.get("when") or "",
                                 desc=child.get("desc") or "",
                                 manifest=manifest_path))

        elif tag == "build":
            _parse_build(child, meta, manifest_path, errors)

        elif tag == "publish":
            # `<publish>` 现在只表达两件文件表达不了的事：推到别的仓（to=）、
            # 不发布（kind="none"）。`kind="script"` / `script=` 已经取消（ADR-023）。
            _parse_publish(child, meta, manifest_path, errors)

        elif tag == "include":
            src = child.get("src")
            optional = _bool_attr(child, "optional")
            if not src or not is_safe_rel(src):
                errors.append("<include src=%r> 必须是不含 .. 的相对路径" % src)
                continue
            inc_path = os.path.join(project_root, src)
            if not os.path.isfile(inc_path):
                if not optional:
                    errors.append("include 目标不存在: %s" % inc_path)
                continue
            inc_text = read_text(inc_path) or ""
            try:
                inc_root = ET.fromstring(inc_text)
            except ET.ParseError as exc:
                errors.append("include XML 解析失败: %s: %s" % (inc_path, exc))
                continue
            _parse_children(inc_root, project_root, inc_path, meta, entries,
                            errors, depth + 1, warnings=warnings)

        else:
            # ‼️ 别再写"自定义元素请用 x-* 前缀"：本解析器对 x-* 一样拒绝 ——
            # 照着改还是同一个错（BL-23）。真出路是 <include>（机器本地差异）。
            errors.append("未知元素 <%s>（%s）；wtool.xml 没有自定义元素（x-* 也拒绝），"
                          "机器本地差异请用 <include src=\"wtool.local.xml\" optional=\"true\"/>"
                          % (tag, manifest_path))


def _home_rel(raw, errors, manifest_path, tag):
    """把 ~/... 或 .config/... 归一成相对 $HOME 的路径。"""
    if not raw:
        return None
    rel = raw
    if rel.startswith("~/"):
        rel = rel[2:]
    elif rel == "~":
        errors.append("<%s> 的 home 不能是 ~ 本身（%s）" % (tag, manifest_path))
        return None
    elif rel.startswith("~"):
        errors.append("<%s> 的路径只认 ~/... 写法，实际 %r" % (tag, raw))
        return None
    rel = rel.lstrip("/")
    if not is_safe_rel(rel):
        errors.append("<%s> 的路径必须是不含 .. 的相对路径，实际 %r" % (tag, raw))
        return None
    return rel


def _parse_link(child, errors, warnings, manifest_path):
    """<link> 是**三段映射**（见 harness/architecture.md §3.2）：

        <link home="~/.tmux.conf"
              wtool="~/.wtool/.tmux.conf"
              subproject="tmux.conf"/>

        <项目>/tmux.conf ──► ~/.wtool/.tmux.conf ──► ~/.tmux.conf

    `home` 是目录、内容由项目自己的 install.sh 产出时，把 subproject 换成
    produced-by="install.sh"（这时没有中间那一跳，实体由脚本铺）。

    旧写法 <link src="tmux.conf" dest=".tmux.conf"/> 仍然认（过渡期），
    等价于 home=dest、wtool=~/.wtool/<dest>、subproject=src。
    """
    home_raw = child.get("home")
    wtool_raw = child.get("wtool")
    sub = child.get("subproject")
    produced = child.get("produced-by")

    if not home_raw and child.get("dest"):
        warnings.append("<link src= dest=> 是旧写法，请改成 "
                        "<link home= wtool= subproject=>（%s）" % manifest_path)
        home_raw = child.get("dest")
        sub = child.get("src")
        wtool_raw = None

    if not home_raw:
        errors.append("<link> 需要 home=\"~/...\"（%s）" % manifest_path)
        return None
    if sub and produced:
        errors.append("<link> 的 subproject 和 produced-by 只能有一个（%s）"
                      % manifest_path)
        return None
    if not sub and not produced:
        errors.append("<link home=%r> 需要 subproject= 或 produced-by=（%s）"
                      % (home_raw, manifest_path))
        return None

    home_rel = _home_rel(home_raw, errors, manifest_path, "link")
    if home_rel is None:
        return None

    if wtool_raw:
        wrel = _home_rel(wtool_raw, errors, manifest_path, "link")
        if wrel is None:
            return None
        if not wrel.startswith(SHADOW_ROOT_NAME + "/"):
            errors.append("<link wtool=%r> 必须写在 ~/%s/ 下面（影子 HOME）（%s）"
                          % (wtool_raw, SHADOW_ROOT_NAME, manifest_path))
            return None
        wtool_rel = wrel[len(SHADOW_ROOT_NAME) + 1:]
    else:
        # 默认镜像路径：$HOME 里的路径在 ~/.wtool 下同名（§8）
        wtool_rel = home_rel

    if produced and produced.strip() != "install.sh":
        errors.append("<link produced-by=%r> 目前只认 install.sh（%s）"
                      % (produced, manifest_path))
        return None

    if sub and not is_safe_rel(sub):
        errors.append("<link subproject=%r> 必须是不含 .. 的相对路径" % sub)
        return None

    return Entry("link", sub or "",
                 home=home_rel, wtool=wtool_rel,
                 produced_by=(produced or "").strip(),
                 force=_bool_attr(child, "force"),
                 optional=_bool_attr(child, "optional"),
                 manifest=manifest_path)


def _parse_system_file(child, errors, manifest_path):
    """系统文件（/etc 下）：src=自己的内容，或 kind=让引擎按发行版生成。

    dest="auto" 只允许和 kind 一起用 —— 目标路径由引擎算（换源就是这种）。
    """
    dest = child.get("dest")
    if dest != "auto" and (not dest or not dest.startswith("/")):
        errors.append("<sudo-install> 的 dest 必须是绝对路径（或 kind 配 dest=\"auto\"）（%s）"
                      % manifest_path)
        return None
    if dest == "auto" and not child.get("kind"):
        errors.append("<sudo-install> dest=\"auto\" 必须和 kind 一起用")
        return None
    src = child.get("src")
    kind = child.get("kind")
    mode = (child.get("mode") or "replace").strip()
    if mode not in ("replace", "add", "disable"):
        errors.append("<sudo-install> mode 只能是 replace/add/disable，实际 %r" % mode)
        return None
    # disable 只是把原文件改名，不需要内容
    if mode != "disable" and not src and not kind:
        errors.append("<sudo-install> 需要 src（自己的内容）或 kind（引擎生成）")
        return None
    return Entry("sysfile", src or "", dest=dest, mode=mode,
                 sf_kind=kind, mirror=child.get("mirror") or "ustc",
                 backup=_bool_attr(child, "backup", default=(mode == "replace")),
                 when=child.get("when") or "",
                 desc=child.get("desc") or "",
                 manifest=manifest_path)


def _parse_sudo_install(child, errors, warnings, manifest_path):
    """<sudo-install>：系统层。**一个标签覆盖那三类内容**（§3.3）：

        <sudo-install src="provision/packages.yaml" marker="apt-base"/>   ← 跑脚本/playbook
        <sudo-install kind="apt-mirror" mirror="ustc" dest="auto"/>       ← 引擎生成的系统文件
        <sudo-install src="my.conf" dest="/etc/foo.conf"/>                ← 项目里带的系统文件

    判据：有 dest=（且是绝对路径或 auto）就是系统文件，否则是要跑的任务。
    系统文件可逆（备份 → 还原），任务不可逆（只记 marker 与 apt 差集）。
    """
    if child.get("dest"):
        entry = _parse_system_file(child, errors, manifest_path)
        return [entry] if entry is not None else []

    src = child.get("src")
    if not src:
        errors.append("<sudo-install> 需要 src 或 dest（%s）" % manifest_path)
        return []
    if not is_safe_rel(src):
        errors.append("<sudo-install src=%r> 必须是不含 .. 的相对路径" % src)
        return []
    # runner= 已经删掉：按扩展名判断（.yaml/.yml → ansible，其余 → shell）
    if child.get("runner"):
        warnings.append("<sudo-install runner=...> 已经删掉，按扩展名自动判断（%s）"
                        % manifest_path)
    runner = "ansible" if src.endswith((".yaml", ".yml")) else "shell"
    return [Entry("task", src, runner=runner,
                  marker=child.get("marker") or "",
                  when=child.get("when") or "",
                  desc=child.get("desc") or "",
                  manifest=manifest_path)]


def _int_attr(node, name, default, errors, where):
    raw = node.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        errors.append("%s 的 %s=%r 不是整数" % (where, name, raw))
        return default


def _bool_attr(node, name, default=False):
    raw = node.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes")


# --------------------------------------------------------------------------
# 镜像源生成（kind="apt-mirror" / "yum-mirror"）
# --------------------------------------------------------------------------
# 镜像表：**和 install.sh 的候选表要对得上**（`bootstrap/scripts/install-env.sh`
# 的 env_mirror_list）。install.sh 挑完之后会把选择记在 <state>/mirror.txt，
# 系统层（项目的 <sudo-install kind="apt-mirror" mirror="auto"/>）照着它来 ——
# 两处各换一次就会出现两份源文件，apt 会警告 "configured multiple times"
# （2026-10-04 实测，见 harness/docs/hazards.md H20）。
APT_MIRRORS = {
    "ustc": "https://mirrors.ustc.edu.cn/ubuntu/",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/",
    "aliyun": "https://mirrors.aliyun.com/ubuntu/",
    "huawei": "https://mirrors.huaweicloud.com/ubuntu/",
    "netease": "https://mirrors.163.com/ubuntu/",
    "tencent": "https://mirrors.cloud.tencent.com/ubuntu/",
}
DEB_MIRRORS = {
    "ustc": "https://mirrors.ustc.edu.cn/debian/",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn/debian/",
    "aliyun": "https://mirrors.aliyun.com/debian/",
    "huawei": "https://mirrors.huaweicloud.com/debian/",
    "netease": "https://mirrors.163.com/debian/",
    "tencent": "https://mirrors.cloud.tencent.com/debian/",
}
YUM_MIRRORS = {
    "ustc": "https://mirrors.ustc.edu.cn",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn",
    "aliyun": "https://mirrors.aliyun.com",
}


def _recorded_mirror(state_dir):
    """install.sh 第 0 步挑过的镜像（`<state>/mirror.txt`，写它的是 install-env.sh）。

    返回 (code, host)：没记录 → ("", "")；选了官方源 → ("official", "")。
    格式：`<代号>\t<主机名|->\t<来源>\t<时间>`。
    """
    text = read_text(os.path.join(state_dir, "mirror.txt"))
    if not text:
        return "", ""
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        code = (parts[0] if parts else "").strip()
        host = (parts[1] if len(parts) > 1 else "").strip()
        if host in ("-", ""):
            host = ""
        return code, host
    return "", ""


def mirror_dest_hint(kind, os_id):
    """换源会写到哪个文件（不渲染内容时也要知道，见 plan_provision 的跳过分支）。"""
    if kind in ("apt-mirror", "distro-mirror") and os_id in ("ubuntu", "debian"):
        return ("/etc/apt/sources.list.d/ubuntu.sources" if os_id == "ubuntu"
                else "/etc/apt/sources.list.d/debian.sources")
    return ""


def mirror_code_of_host(os_id, host):
    """给定主机名，反查它在我们表里的代号（不是我们认得的镜像 → ""）。"""
    if not host:
        return ""
    table = APT_MIRRORS if os_id == "ubuntu" else (
        DEB_MIRRORS if os_id == "debian" else {})
    for code, uri in table.items():
        if host in uri:
            return code
    return ""


def render_distro_mirror(kind, os_id, codename, mirror, errors):
    """按发行版生成镜像源文件内容。返回 (content, dest_hint)。"""
    mirror = (mirror or "ustc").lower()

    if kind in ("apt-mirror", "distro-mirror") and os_id in ("ubuntu", "debian"):
        table = APT_MIRRORS if os_id == "ubuntu" else DEB_MIRRORS
        uri = table.get(mirror)
        if not uri:
            errors.append("未知镜像 %r（支持: %s）" % (mirror, ",".join(sorted(table))))
            return None, None
        if not codename:
            errors.append("无法确定 %s 的 codename（/etc/os-release 里没有 VERSION_CODENAME）" % os_id)
            return None, None
        keyring = ("/usr/share/keyrings/ubuntu-archive-keyring.gpg" if os_id == "ubuntu"
                   else "/usr/share/keyrings/debian-archive-keyring.gpg")
        suites = "%s %s-updates %s-backports %s-security" % (codename, codename, codename, codename)
        if os_id == "debian":
            suites = "%s %s-updates %s-security" % (codename, codename, codename)
        content = (
            "# 由 wtool 生成（kind=%s mirror=%s）—— 如需修改请改清单后重跑\n"
            "Types: deb\n"
            "URIs: %s\n"
            "Suites: %s\n"
            "Components: main universe restricted multiverse\n"
            "Signed-By: %s\n" % (kind, mirror, uri, suites, keyring)
        )
        dest = "/etc/apt/sources.list.d/ubuntu.sources" if os_id == "ubuntu" \
               else "/etc/apt/sources.list.d/debian.sources"
        return content, dest

    if kind in ("yum-mirror", "distro-mirror") and os_id in (
            "rocky", "centos", "rhel", "almalinux", "fedora"):
        base = YUM_MIRRORS.get(mirror)
        if not base:
            errors.append("未知镜像 %r" % mirror)
            return None, None
        path = {"rocky": "/rocky", "centos": "/centos", "almalinux": "/almalinux",
                "rhel": "/rocky", "fedora": "/fedora"}.get(os_id, "/" + os_id)
        content = (
            "# 由 wtool 生成（kind=%s mirror=%s）\n"
            "[wtool-baseos]\n"
            "name=wtool baseos ($releasever)\n"
            "baseurl=%s%s/$releasever/BaseOS/$basearch/os/\n"
            "enabled=1\n"
            "gpgcheck=1\n\n"
            "[wtool-appstream]\n"
            "name=wtool appstream ($releasever)\n"
            "baseurl=%s%s/$releasever/AppStream/$basearch/os/\n"
            "enabled=1\n"
            "gpgcheck=1\n" % (kind, mirror, base, path, base, path)
        )
        return content, "/etc/yum.repos.d/wtool-mirror.repo"

    errors.append("kind=%r 不支持发行版 %r（支持 ubuntu/debian/rocky/centos/rhel/almalinux/fedora）"
                  % (kind, os_id))
    return None, None


# --------------------------------------------------------------------------
# 校验
# --------------------------------------------------------------------------
def validate_entries(entries, project_root, home, state_dir, errors, warnings):
    seen_dest = {}

    for entry in entries:
        # link 有自己的两跳路径规则，先单独走
        if entry.kind == "link":
            _validate_link(entry, project_root, home, errors, warnings, seen_dest)
            continue
        # 只有 env / task 的 src 是"项目内相对路径"；
        # sysfile 的 src 可选（也可用 kind 生成），source 的 src 是 URL
        if entry.kind in ("sysfile", "source"):
            if entry.kind == "sysfile" and entry.src and not is_safe_rel(entry.src):
                errors.append("sysfile src=%r 必须是不含 .. 的相对路径" % entry.src)
            continue
        if not is_safe_rel(entry.src):
            errors.append("%s src=%r 必须是不含 .. 的相对路径"
                          % (entry.kind, entry.src))
            continue
        abs_src = os.path.join(project_root, entry.src)
        if not os.path.exists(abs_src):
            if getattr(entry, "optional", False):
                warnings.append("%s src 不存在（optional，跳过）: %s"
                                % (entry.kind, entry.src))
                entry.skip = True
                continue
            errors.append("%s src 不存在: %s" % (entry.kind, abs_src))
            continue
        if not is_under(abs_src, project_root):
            errors.append("%s src 逃出项目目录: %s" % (entry.kind, entry.src))
            continue

        if entry.kind == "env":
            if entry.shells:
                entry.rc_files = [os.path.join(home, RC_FILE_BY_SHELL[s])
                                  for s in entry.shells if s in RC_CAPABLE_SHELLS]
            else:
                entry.rc_files = []
            entry.abs_src = abs_src

    # 跨仓冲突：registry 里 dest 被别的项目占了
    registry = _read_registry(os.path.join(state_dir, "registry.tsv"))
    return registry


def _validate_link(entry, project_root, home, errors, warnings, seen_dest):
    """算出 <link> 两跳的绝对路径，并检查源与落点。"""
    shadow = os.path.join(home, SHADOW_ROOT_NAME)
    abs_dest = os.path.join(home, entry.home)
    abs_wtool = os.path.join(shadow, entry.wtool)
    if not is_under(abs_dest, home):
        errors.append("link home 逃出 $HOME: %s" % entry.home)
        return
    if not is_under(abs_wtool, shadow) or abs_wtool == shadow:
        errors.append("link wtool 逃出 ~/%s: %s" % (SHADOW_ROOT_NAME, entry.wtool))
        return
    if abs_dest in seen_dest:
        errors.append("同一个清单里 home 重复: %s" % entry.home)
        return
    # home 那一跳的落点在 $HOME 里；中间那一跳是我们自己造的，允许已存在
    seen_dest[abs_dest] = entry
    entry.abs_dest = abs_dest
    entry.abs_wtool = abs_wtool

    if entry.src:                       # subproject：内容来自项目目录
        if not is_safe_rel(entry.src):
            errors.append("link subproject=%r 必须是不含 .. 的相对路径" % entry.src)
            return
        abs_src = os.path.join(project_root, entry.src)
        if not os.path.exists(abs_src):
            if getattr(entry, "optional", False):
                warnings.append("link subproject 不存在（optional，跳过）: %s"
                                % entry.src)
                entry.skip = True
                return
            errors.append("link subproject 不存在: %s" % abs_src)
            return
        if not is_under(abs_src, project_root):
            errors.append("link subproject 逃出项目目录: %s" % entry.src)
            return
        entry.abs_src = abs_src
    # produced-by=install.sh：实体由项目脚本铺，这一跳只要落点没被占就行


def _read_registry(path):
    out = {}
    text = read_text(path)
    if not text:
        return out
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            out[parts[0]] = parts[1]
    return out


# --------------------------------------------------------------------------
# rc 块
# --------------------------------------------------------------------------
def parse_block_attrs(attr_text):
    return dict(ATTR_RE.findall(attr_text))


def render_block(project_id, schema, prio, head, manifest_sha, env_rel):
    """受管块只放"稳定"字段。

    刻意不放时间戳：块是契约，不是日志。任何会让重复 install 产生
    新内容的字段都会破坏幂等性（时间戳属于这类），时间等溯源信息
    统一记在 $WTOOL_STATE/<id>/meta.tsv 里。

    块内容只依赖 project_id（和 env 的相对路径），所以仓库搬到任何位置，
    块都一个字不用改；WTOOL_PROJECT_ROOT 在 source 时由中转链接实时解析。
    """
    begin = ("# >>> wtool:%s schema=%d engine=%s prio=%d head=%s manifest=%s >>>"
             % (project_id, schema, ENGINE_VERSION, prio, head or "-",
                (manifest_sha or "-")[:12]))
    link_dir = links_dir_shell(project_id)
    body = [
        # 这三个变量只在 source 期间有效；env 文件应把它们拷进自己的变量
        "WTOOL_PROJECT_ID='%s'" % project_id,
        "WTOOL_PROJECT_DIR=%s" % link_dir,
        "export WTOOL_PROJECT_ID WTOOL_PROJECT_DIR",
        'WTOOL_PROJECT_ROOT=$(readlink -f -- "$WTOOL_PROJECT_DIR" 2>/dev/null '
        '|| printf \'%s\' "$WTOOL_PROJECT_DIR")',
        "export WTOOL_PROJECT_ROOT",
        '[ -r "$WTOOL_PROJECT_DIR/%s" ] && . "$WTOOL_PROJECT_DIR/%s"'
        % (env_rel, env_rel),
    ]
    end = "# <<< wtool:%s <<<" % project_id
    return [begin] + body + [end]


def find_blocks(lines):
    """返回 [(start, end_inclusive, id, prio), ...]"""
    blocks = []
    i = 0
    while i < len(lines):
        m = BLOCK_BEGIN_RE.match(lines[i])
        if not m:
            i += 1
            continue
        bid = m.group(1)
        attrs = parse_block_attrs(m.group(2))
        try:
            prio = int(attrs.get("prio", DEFAULT_PRIORITY))
        except ValueError:
            prio = DEFAULT_PRIORITY
        j = i + 1
        while j < len(lines):
            e = BLOCK_END_RE.match(lines[j])
            if e and e.group(1) == bid:
                break
            j += 1
        if j < len(lines):
            blocks.append((i, j, bid, prio))
            i = j + 1
        else:
            # 没有结束标记：保守起见不认，避免误删用户内容
            i += 1
    return blocks


def split_lines(text):
    if text is None:
        return []
    if text == "":
        return []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def merge_rc(text, project_id, block, prio, remove_only):
    """返回 (new_text, removed_block_sha_or_None, changed)"""
    lines = split_lines(text)
    blocks = find_blocks(lines)
    mine = [b for b in blocks if b[2] == project_id]

    removed_sha = None
    if mine:
        s, e, _, _ = mine[0]
        removed_sha = sha256_text("\n".join(lines[s:e + 1]) + "\n")
        if remove_only or block is None:
            lines = lines[:s] + lines[e + 1:]
        else:
            lines = lines[:s] + list(block) + lines[e + 1:]
    else:
        if remove_only or block is None:
            new_text = "\n".join(lines) + ("\n" if lines else "")
            return new_text, None, False
        blocks = find_blocks(lines)
        key = (prio, project_id)
        insert_at = None
        for (s, e, bid, bprio) in blocks:
            if (bprio, bid) < key:
                insert_at = e + 1
        if insert_at is None:
            # 没有比我更靠前的块：插到最前面，保证顺序与安装先后无关
            insert_at = blocks[0][0] if blocks else len(lines)
        # 不额外插入空行：任何"装饰性"空行都会在卸载后残留，
        # 破坏"install→uninstall 内容字节级还原"这条不变量。
        lines = lines[:insert_at] + list(block) + lines[insert_at:]

    new_text = "\n".join(lines) + ("\n" if lines else "")
    changed = new_text != (text if text is not None else "")
    return new_text, removed_sha, changed


# --------------------------------------------------------------------------
# 规划
# --------------------------------------------------------------------------
def _link_hops(entry, link_dir):
    """一条 <link> 声明要建的软链：[(落点, 指向), ...]，顺序就是建链顺序。

    中间那一跳（影子 HOME 里的实体）在前，$HOME 里那一跳在后 ——
    建第二跳的时候第一跳必须已经在，否则就是一条悬空链。
    """
    hops = []
    if entry.src:
        hops.append((entry.abs_wtool, os.path.join(link_dir, entry.src)))
    hops.append((entry.abs_dest, entry.abs_wtool))
    return hops


def _prune_rows(state_dir, project_id, owned, registry, link_dir):
    """`install --prune`：清掉「清单里已经删掉、磁盘上还在」的软链（BL-15）。

    判据是 **journal**（"我做过什么"）而不是磁盘扫描：只有我们自己记过账的落点
    才动。这样别人的软链、用户自己建的东西，一概不碰 —— 扫磁盘"看着像我们的就删"
    会删掉用户的东西，那是不可逆的错。

    三道刹车：
      · 落点这次清单里还有（owned）→ 不删
      · registry 说这条属于**另一个项目**（链接搬家了）→ 不删，留给那个项目
      · 磁盘上指向已经变了（用户改过）→ sh 那一侧再验一次才删
    """
    journal = os.path.join(state_dir, project_id, "journal.tsv")
    rows = []
    text = read_text(journal)
    if not text:
        return rows
    stale_dirs = []
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) < 4:
            continue
        action, dest, target = f[0], f[2], f[3]
        if action == "link":
            if dest in owned or dest == link_dir:
                continue
            owner = registry.get(dest)
            if owner and owner != project_id:
                continue          # 这条现在归别人（或改装到别人名下）—— 别越权
            rows.append(("prune", f[1] if len(f) > 1 and f[1] else "file",
                         dest, target or "-", "", ""))
        elif action == "mkdir":
            # 顺手收走"这条软链的父目录是我们建的"那种空目录。
            # 只有空目录会被删（wt_remove_dir_if_empty），非空一律留着。
            if not any(o == dest or o.startswith(dest.rstrip("/") + "/") for o in owned):
                stale_dirs.append(dest)
    # 深的先删：先删 ~/.config/foo/bar，才轮得到 ~/.config/foo
    for d in sorted(set(stale_dirs), key=len, reverse=True):
        rows.append(("prune-dir", "dir", d, "", "", ""))
    return rows


def plan_install(args, scratch):
    project_root = os.path.abspath(args.project)
    home = os.path.abspath(args.home)
    state_dir = os.path.abspath(args.state)

    errors, warnings = [], []
    manifest_path = os.path.join(project_root, "wtool.xml")
    meta, entries = parse_manifest(manifest_path, project_root, errors, warnings)
    if meta is None:
        raise PlanError("\n".join(errors))

    project_id = project_id_of(project_root, args.root or None)
    if not is_safe_rel(project_id):
        errors.append("项目身份非法: %r（项目得在工作区里，身份就是它的相对路径）" % project_id)

    registry = validate_entries(entries, project_root, home, state_dir, errors, warnings)
    conflicts = []
    for entry in entries:
        if getattr(entry, "skip", False) or not hasattr(entry, "abs_dest"):
            continue
        owner = registry.get(entry.abs_dest)
        if owner and owner != project_id:
            conflicts.append("dest 已被项目 %s 占用: %s" % (owner, entry.abs_dest))
    if conflicts:
        if args.force:
            warnings.extend(conflicts)
        else:
            errors.extend(conflicts)

    # 磁盘冲突检测
    link_dir = links_dir_for(home, project_id)
    for entry in entries:
        if entry.kind != "link" or getattr(entry, "skip", False):
            continue
        for dest, want in _link_hops(entry, link_dir):
            if os.path.islink(dest):
                current = os.readlink(dest)
                if os.path.normpath(current) != os.path.normpath(want):
                    msg = "dest 已是软链但指向别处: %s -> %s" % (dest, current)
                    (warnings if (args.force or entry.force) else errors).append(msg)
            elif os.path.lexists(dest):
                msg = "dest 已存在且不是软链: %s" % dest
                (warnings if (args.force or entry.force) else errors).append(msg)

    if errors:
        raise PlanError("\n".join(errors))

    rows = []          # 引擎基建：中转链接 + env 块（项目 install.sh **之前**）
    home_rows = []     # 声明面：$HOME 里的软链（install.sh **之后**，见 §4.2）
    owned = set()      # 这次清单声明要有的落点（--prune 用它判断"哪些已经不该在"）

    def add_link(bucket, kind, dest, target):
        """reg 行始终发出（保持 registry 与磁盘一致）；
        link 行只在软链缺失/指向不对时才发出，这样重复 install 才是真正的 no-op。"""
        bucket.append(("reg", kind, dest, "", "", ""))
        owned.add(os.path.normpath(dest))
        want = os.path.normpath(target)
        if os.path.islink(dest) and os.path.normpath(os.readlink(dest)) == want:
            return
        bucket.append(("link", kind, dest, target, "", ""))

    # 1) 稳定中转链接 ~/.wtool/wtool-work-dir/links/<id> -> <project_root>
    add_link(rows, "dir", link_dir, project_root)

    # 2) 项目内的软链，走**两跳**（§3.2）：
    #       <项目>/<subproject> → ~/.wtool/<wtool> → $HOME/<home>
    #    中间那一跳是实体落点（也进影子 HOME 的镜像规则），最后一跳才是
    #    应用去找的那个位置。produced-by 的中间那一跳由项目 install.sh 铺，
    #    引擎只建最后一跳。
    for entry in entries:
        if entry.kind != "link" or getattr(entry, "skip", False):
            continue
        for dest, want in _link_hops(entry, link_dir):
            bucket = home_rows if dest == entry.abs_dest else rows
            add_link(bucket, "file", dest, want)

    # 3) rc 注入
    rc_index = 0
    desired = {}  # rcfile -> env_rel
    for entry in entries:
        if entry.kind != "env" or getattr(entry, "skip", False):
            continue
        for rc in entry.rc_files:
            desired[rc] = entry.src

    # 每个项目的环境变量不再直接写进用户的 ~/.zshrc，而是各自写成一个块文件
    # 放在状态目录里；用户的 rc 里只留**一个** loader 块，source 汇总文件。
    #
    # 好处：wtool 从此不需要在用户真正的 rc 里做"按优先级排序插入"这种危险操作，
    # 排序和增删全在自己生成的文件里做，出错也炸不到用户的东西。
    # 想彻底去掉 wtool 对环境的影响，删掉那一个块即可。
    state = os.path.abspath(args.state)
    for rc, env_rel in sorted(desired.items()):
        shell = "zsh" if rc.endswith("zshrc") else "bash"
        block = render_block(project_id, meta["schema"], meta["priority"],
                             args.head, meta["manifest_sha"], env_rel)
        new_text = "\n".join(block) + "\n"
        dest = os.path.join(state, project_id, "env.%s" % shell)
        # 内容没变就别出这条动作，否则每次 install 都"有变更"，
        # 幂等性检查（和"没有需要变更的内容"这句提示）都会失效
        if read_text(dest) == new_text:
            continue
        blk_file = os.path.join(scratch, "envblock.%s" % shell)
        with open(blk_file, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(new_text)
        rows.append(("envblock", shell, dest, blk_file,
                     sha256_text(new_text), env_rel))

    # 可选的收尾清理（BL-15）：`wtool install <项目> --prune`
    if getattr(args, "prune", False):
        rows.extend(_prune_rows(state_dir, project_id, owned, registry, link_dir))

    _write_plan(scratch, rows)
    _write_plan(scratch, home_rows, "plan.home.tsv")
    _write_meta(scratch, {
        "project_id": project_id,
        "project_root": project_root,
        "schema": meta["schema"],
        "priority": meta["priority"],
        "manifest_sha": meta["manifest_sha"],
        "head": args.head or "-",
        "at": args.at or "-",
        "engine": ENGINE_VERSION,
    })
    return {
        "project_id": project_id,
        "project_root": project_root,
        "meta": meta,
        "rows": rows,
        "home_rows": home_rows,
        "warnings": warnings,
    }


def plan_uninstall(args, scratch):
    """规划 uninstall。项目身份 = 路径（没有 id 了）。

    两条输入，都由 `wtool.sh` 解析好传进来：
      * `args.project`      —— 用户敲的那个路径（相对工作区根，或绝对路径）
      * `args.project_root` —— 真实目录（引擎解析出来的；目录已经不在了就是 ""）

    目录还在 → 身份由**真实路径**算（和 plan_install 用同一个 `project_id_of`，
    这样两边永远一致）；目录没了 → 用户给的那条相对路径**就是**身份
    （state 目录当初就是按它建的，所以账还找得到）。
    """
    home = os.path.abspath(args.home)
    root = args.root or os.environ.get("WTOOL_ROOT") or ""
    errors, warnings = [], []

    if args.project_root:
        project_root = os.path.abspath(args.project_root)
        project_id = project_id_of(project_root, root or None)
    else:
        project_root = None
        want = (args.project or "").strip()
        if not want:
            raise PlanError("uninstall 需要项目路径（相对工作区根，或绝对路径）")
        # 绝对路径但目录已经不在：退回它相对工作区根的写法；工作区外面就取目录名。
        project_id = project_id_of(want, root or None) if os.path.isabs(want) \
            else want.rstrip("/")
    if not is_safe_rel(project_id):
        raise PlanError("项目身份非法: %r（给相对工作区根的路径）" % project_id)

    rows = []
    # 删掉这个项目的 env 块文件。汇总文件由 shell 侧的 wt_env_sync 重新生成，
    # 块文件一没，这个项目自然就从汇总里消失了。
    state = os.path.abspath(args.state)
    for shell in ("zsh", "bash"):
        blk = os.path.join(state, project_id, "env.%s" % shell)
        if os.path.isfile(blk):
            rows.append(("envblock-del", shell, blk, "-", "-", "-"))
    # 老版本把块直接写在用户的 rc 里，这里顺手清掉（迁移）
    for rc in sorted(_rcs_with_our_block(home, project_id)):
        old = read_text(rc)
        new_text, removed_sha, changed = merge_rc(old, project_id, None,
                                                  DEFAULT_PRIORITY, True)
        if not changed:
            continue
        rc_file = os.path.join(scratch, "rc.%d" % len(rows))
        with open(rc_file, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(new_text)
        rows.append(("rc", "file", rc, rc_file, sha256_text(new_text),
                     removed_sha or "-"))

    _write_plan(scratch, rows)
    _write_meta(scratch, {
        "project_id": project_id,
        "project_root": project_root or "-",
        "engine": ENGINE_VERSION,
        "head": args.head or "-",
        "at": args.at or "-",
    })
    return {"project_id": project_id, "rows": rows, "warnings": warnings}


def _rcs_with_our_block(home, project_id):
    out = []
    for name in sorted(set(RC_FILE_BY_SHELL.values())):
        path = os.path.join(home, name)
        text = read_text(path)
        if text is None:
            continue
        if any(b[2] == project_id for b in find_blocks(split_lines(text))):
            out.append(path)
    return out


def when_matches(when, os_id, arch):
    """逗号分隔 = AND。

    支持：os:ubuntu / !os:debian / arch:x86_64 / env:WTOOL_HEAVY
    env:NAME 表示"环境变量 NAME 有值且不是 0/false" —— 用来做可选的重型步骤。
    """
    if not when:
        return True
    for cond in when.replace(",", " ").split():
        if cond.startswith("!os:"):
            if os_id == cond[4:]:
                return False
        elif cond.startswith("os:"):
            if os_id != cond[3:]:
                return False
        elif cond.startswith("arch:"):
            if arch != cond[5:]:
                return False
        elif cond.startswith("env:"):
            raw = os.environ.get(cond[4:], "")
            if raw.strip().lower() in ("", "0", "false", "no"):
                return False
        else:
            return False        # 未知条件按不匹配处理，避免误执行
    return True


def provision_packages(args):
    """从 playbook 里把包名抠出来（一行一个）。

    为什么不上 YAML 库：这一步可能在 **ansible 还没装**的时候跑（规划 / 打印
    "这一步要装几个包"），不能依赖 PyYAML。这些 playbook 是我们自己的，
    结构就是 `name:` 下面一串 `- 包名`；解析不出来就少说一句，绝不猜。
    """
    names, seen, in_list = [], set(), False
    try:
        with open(args.playbook, encoding="utf-8", errors="surrogateescape") as fh:
            lines = fh.readlines()
    except OSError as exc:
        raise SystemExit("读不了 %s: %s" % (args.playbook, exc))

    for raw in lines:
        line = raw.rstrip("\n")
        if line.lstrip().startswith("#"):
            continue
        # 行尾注释要去掉再匹配：`- tree   # 说明` 这种，不去掉就既不匹配
        # "一个包名"、又把 in_list 关掉，后面那一串包全丢（测试抓到过）
        line = re.sub(r"\s+#.*$", "", line)
        stripped = line.strip()
        m = re.match(r"^\s*name:\s*(.*)$", line)
        if m and not stripped.startswith("- name:"):
            rest = m.group(1).strip()
            if rest in ("", "|", ">"):
                in_list = True
                continue
            in_list = False
            if rest.startswith("["):          # name: [a, b, c]
                for item in rest.strip("[]").split(","):
                    item = item.strip().strip("'\"")
                    if item and item not in seen:
                        seen.add(item)
                        names.append(item)
            continue
        if in_list:
            m2 = re.match(r"^\s*-\s+(\S+)\s*$", line)
            if m2:
                item = m2.group(1).strip("'\"")
                if item and item not in seen:
                    seen.add(item)
                    names.append(item)
                continue
            if stripped:
                in_list = False
    for name in names:
        print(name)


def plan_provision(args, scratch):
    """规划 provision：system-file → source → task 三个阶段。"""
    project_root = os.path.abspath(args.project)
    home = os.path.abspath(args.home)
    state_dir = os.path.abspath(args.state)
    errors, warnings = [], []
    os.makedirs(scratch, exist_ok=True)

    manifest_path = os.path.join(project_root, "wtool.xml")
    meta, entries = parse_manifest(manifest_path, project_root, errors, warnings)
    if meta is None:
        raise PlanError("\n".join(errors))

    project_id = project_id_of(project_root, args.root or None)
    if not is_safe_rel(project_id):
        errors.append("项目身份非法: %r（项目得在工作区里，身份就是它的相对路径）" % project_id)

    sysfile_rows = []
    source_rows = []
    task_rows = []
    idx = 0

    for entry in entries:
        if entry.kind == "sysfile":
            if not when_matches(getattr(entry, "when", ""), args.os_id, args.arch):
                warnings.append("when=%s 不匹配，跳过系统文件 %s" % (entry.when, entry.dest))
                continue
            dest = entry.dest
            # disable 只是把原文件改名，先处理掉，不需要内容
            if entry.mode == "disable":
                sysfile_rows.append(("disable", dest, "", "", "no", entry.desc))
                continue
            if entry.src:
                if not is_safe_rel(entry.src):
                    errors.append("system-file src=%r 必须是相对路径" % entry.src)
                    continue
                abs_src = os.path.join(project_root, entry.src)
                if not os.path.isfile(abs_src):
                    errors.append("system-file src 不存在: %s" % abs_src)
                    continue
                content = read_text(abs_src)
            else:
                # `mirror="auto"` = **听 install.sh 的**（用户 2026-10-04 要求：
                # 换源只有一处逻辑，换过一次就不再换）。
                #
                # 为什么必须这样：install.sh 第 0 步已经测速换过一次源（写
                # /etc/apt/sources.list.d/wtool-mirror.sources 并把选择记在
                # <state>/mirror.txt）。系统层再按清单里写死的 mirror="ustc"
                # 写一份 ubuntu.sources，机器上就有两份源文件 —— apt 会警告
                # "Target Packages ... is configured multiple times"，
                # 而且 ansible 的装包任务会因此失败（实测）。
                _mirror = (entry.mirror or "ustc").lower()
                if _mirror == "auto":
                    _rec_code, _rec_host = _recorded_mirror(state_dir)
                    _hint = mirror_dest_hint(entry.sf_kind, args.os_id)
                    if _rec_code == "official":
                        warnings.append(
                            "install.sh 里选了官方源 → 跳过换源（%s）" % (entry.desc or entry.dest))
                        if _hint and entry.dest == "auto":
                            sysfile_rows.append(("dedup", _hint, "", "", "no", entry.desc))
                        continue
                    _rec_mirror = mirror_code_of_host(args.os_id, _rec_host)
                    if _rec_mirror:
                        warnings.append(
                            "这台机器已经换过源（install.sh 选了 %s）→ 跳过换源，"
                            "顺手清掉会重复的那份" % _rec_host)
                        if _hint and entry.dest == "auto":
                            sysfile_rows.append(("dedup", _hint, "", "", "no", entry.desc))
                        continue
                    _mirror = "ustc"      # install.sh 没说过 → 用老默认
                content, dest_hint = render_distro_mirror(
                    entry.sf_kind, args.os_id, args.os_codename, _mirror, errors)
                if content is None:
                    continue
                if entry.dest == "auto":
                    dest = dest_hint
            cf = os.path.join(scratch, "sysfile.%d" % idx)
            idx += 1
            with open(cf, "w", encoding="utf-8") as fh:
                fh.write(content)
            sysfile_rows.append((entry.mode, dest, cf, sha256_text(content),
                                 "yes" if entry.backup else "no", entry.desc))

        elif entry.kind == "source":
            if not when_matches(getattr(entry, "when", ""), args.os_id, args.arch):
                warnings.append("when=%s 不匹配，跳过 source %s" % (entry.when, entry.src))
                continue
            src_dir = entry.dir or "$WTOOL_SRC/" + project_id.split("/")[-1]
            src_dir = src_dir.replace("$WTOOL_SRC", args.src_root)
            overlay = os.path.join(project_root, entry.overlay)
            if not os.path.isdir(overlay):
                overlay = ""
            source_rows.append((src_dir, entry.src, entry.ref, entry.branch, overlay))

        elif entry.kind == "task":
            if not is_safe_rel(entry.src):
                errors.append("provision src=%r 必须是相对路径" % entry.src)
                continue
            # 解析顺序：源码树（overlay 铺进去之后）> 项目根
            # 这样 wsw.sh 可以放在 overlay/ 里，编译时它在源码树根目录
            abs_src = ""
            for entry_src in entries:
                if entry_src.kind == "source":
                    ov = os.path.join(project_root, entry_src.overlay, entry.src)
                    if os.path.isfile(ov):
                        sdir = entry_src.dir or "$WTOOL_SRC/" + project_id.split("/")[-1]
                        sdir = sdir.replace("$WTOOL_SRC", args.src_root)
                        abs_src = os.path.join(sdir, entry.src)
                        break
            if not abs_src:
                cand = os.path.join(project_root, entry.src)
                if os.path.isfile(cand):
                    abs_src = cand
            if not abs_src:
                errors.append("provision src 找不到（项目根或 overlay/ 下都没有）: %s" % entry.src)
                continue
            # 计划阶段就把 when 不匹配的任务剔掉，这样 --dry-run 报的数字是准的
            if not when_matches(entry.when, args.os_id, args.arch):
                warnings.append("when=%s 不匹配，跳过任务 %s"
                                % (entry.when, entry.desc or entry.src))
                continue
            task_rows.append((entry.runner, abs_src, entry.marker,
                              entry.desc or entry.src, entry.when))

    if errors:
        raise PlanError("\n".join(errors))

    os.makedirs(scratch, exist_ok=True)
    with open(os.path.join(scratch, "sysfiles.tsv"), "w", encoding="utf-8") as fh:
        for row in sysfile_rows:
            fh.write("\t".join(row) + "\n")
    with open(os.path.join(scratch, "sources.tsv"), "w", encoding="utf-8") as fh:
        for row in source_rows:
            fh.write("\t".join(row) + "\n")
    with open(os.path.join(scratch, "tasks.tsv"), "w", encoding="utf-8") as fh:
        for row in task_rows:
            fh.write("\t".join(row) + "\n")

    _write_meta(scratch, {
        "project_id": project_id,
        "project_root": project_root,
        "engine": ENGINE_VERSION,
        "os_id": args.os_id or "-",
        "os_version": args.os_version or "-",
        "os_codename": args.os_codename or "-",
        "arch": args.arch or "-",
        "jobs": args.jobs or "-",
        "prefix": args.prefix or "-",
        "src_root": args.src_root or "-",
    })
    return {"project_id": project_id, "warnings": warnings,
            "sysfiles": sysfile_rows, "sources": source_rows, "tasks": task_rows}


def _write_plan(scratch, rows, name="plan.tsv"):
    os.makedirs(scratch, exist_ok=True)
    with open(os.path.join(scratch, name), "w",
              encoding="utf-8", errors="surrogateescape") as fh:
        for row in rows:
            fh.write("\t".join(row) + "\n")


def _write_meta(scratch, mapping):
    os.makedirs(scratch, exist_ok=True)
    with open(os.path.join(scratch, "meta.tsv"), "w", encoding="utf-8") as fh:
        for key, value in mapping.items():
            fh.write("%s\t%s\n" % (key, value))


# --------------------------------------------------------------------------
# 表格：一行一个项目，一列一个能力
#
# 四种状态是**中文词**（常量见下面 LBL_*）：不支持 / 可执行 / 待构建下载 / 已完成。
# 早先用的是 ASCII `+ - .` 三个符号，已经废弃：符号没有约定俗成的含义，
# 看表的人（包括三个月后的自己）得先猜一遍；而"没这项能力"和"有能力但还没做"
# 共用一个 `.` 更会混。用文字也不是为了好看 —— 管道里（--color=never）
# 或色盲用户看到的仍然可读。
# --------------------------------------------------------------------------
def _width(text):
    """显示宽度：CJK 和全角符号占 2 列，其余占 1 列。"""
    w = 0
    for ch in text:
        o = ord(ch)
        if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF or
                0xAC00 <= o <= 0xD7A3 or 0xF900 <= o <= 0xFAFF or
                0xFE30 <= o <= 0xFE6F or 0xFF00 <= o <= 0xFF60 or
                0xFFE0 <= o <= 0xFFE6):
            w += 2
        else:
            w += 1
    return w


def _pad(text, width):
    """按显示宽度右侧补空格。ANSI 转义序列不占宽度，要排掉再算。"""
    return text + " " * max(0, width - _width(_strip_ansi(text)))


ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def _strip_ansi(text):
    return ANSI_RE.sub("", text)


def _read_tsv(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                rows.append(line.split("\t"))
    except OSError:
        pass
    return rows


def project_state(project_root, state_dir, root=None):
    """从 state 目录读出这个项目"做到哪一步了"。只看文件，不写。

    项目 id 必须相对**工作区根**算，不能靠环境变量推：WTOOL_ROOT 在 shell 侧
    只是个普通赋值、没 export，读不到就会退化成"项目目录的 basename"，
    于是 terminal/tmux 被当成 tmux，跟 $WTOOL_STATE/terminal/tmux 对不上，
    表格里已发布的项目显示成没发布。只有 id 恰好等于目录名的项目才碰巧对。
    """
    root = root or os.environ.get("WTOOL_ROOT") or os.path.dirname(os.path.abspath(project_root))
    pid = os.path.relpath(os.path.abspath(project_root), os.path.abspath(root))
    if pid in (".", "/"):
        pid = os.path.basename(os.path.abspath(project_root))
    pdir = os.path.join(state_dir, pid)

    # 做过哪些动作（build / download）。actions.tsv 只追加，不参与回滚，
    # 和 journal 是两件事，所以分开两张表。
    actions = {}
    for row in _read_tsv(os.path.join(pdir, "actions.tsv")):
        if row and len(row) >= 2:
            actions[row[0]] = row[1]
    # 产物清单：当前磁盘上的东西是谁产出的（build 还是 download）
    artifacts = _read_tsv(os.path.join(pdir, "artifacts.tsv"))
    artifact_source = ""
    for row in artifacts:
        if len(row) >= 3 and row[2]:
            artifact_source = row[2]
            break

    # install 过没有：journal 里有非注释行，或者 registry 里登记了它的软链
    journal = os.path.join(pdir, "journal.tsv")
    installed = any(True for _ in _read_tsv(journal))
    if not installed:
        for row in _read_tsv(os.path.join(state_dir, "registry.tsv")):
            if len(row) >= 2 and row[1] == pid:
                installed = True
                break

    # provision 过没有：marker 目录里有东西，或者 provision.log 里记了
    prov_dir = os.path.join(pdir, "provisioned")
    markers = 0
    if os.path.isdir(prov_dir):
        markers = len(os.listdir(prov_dir))
    sysdir = os.path.join(pdir, "system")
    sysfiles = len(os.listdir(sysdir)) if os.path.isdir(sysdir) else 0
    provisioned = markers > 0 or sysfiles > 0

    # 发布过没有：本地发布记录
    published = any(True for _ in _read_tsv(os.path.join(pdir, "publish.tsv")))

    return {"id": pid, "installed": installed, "provisioned": provisioned,
            "published": published, "markers": markers, "sysfiles": sysfiles,
            "actions": actions, "artifacts": artifacts,
            "artifact_source": artifact_source}


# 表格里的四种状态。用文字而不是符号：圆点、横杠这类符号没有约定俗成的含义，
# 看表的人（包括三个月后的自己）得先猜一遍。
LBL_NONE = "不支持"
LBL_TODO = "待产出"
LBL_CAN = "可执行"
LBL_DONE = "已完成"
# 第 5 个标签：项目还没发布过（仓库里没有 scripts/release.json）——
# 它和"待产出"不是一回事：产出是本机的事，发布是另一台机器上的事。
LBL_UNPUB = "未发布"
# 「未安装」：这条 uninstall 命令**现在没什么可撤的**（还没装）。
# 它和「不支持」不一样 —— 不支持是"这项目根本没这项能力"。
# 用户 2026-10-04 要求：install 旁边跟一列 uninstall，装之前是未安装、
# 装之后变可执行；sudo 那一对同理。
LBL_NOTINST = "未安装"

C_RED = "\033[31m"
C_YELLOW = "\033[33m"
C_GREEN = "\033[32m"
C_BLUE = "\033[34m"
C_MAGENTA = "\033[35m"
C_CYAN = "\033[36m"
C_OFF = "\033[0m"

_LBL_COLOR = {LBL_NONE: C_RED, LBL_TODO: C_BLUE, LBL_CAN: C_YELLOW,
              LBL_DONE: C_GREEN, LBL_UNPUB: C_MAGENTA, LBL_NOTINST: C_CYAN}


def _state_cell(state, color_on):
    if not color_on:
        return state
    return _LBL_COLOR[state] + state + C_OFF


def pipeline_states(path, pub, st):
    """算出这个项目在表格里的状态。

    这是一条流水线：**产出** → `install`。产出有两条来路 ——
    `wtool build`，或者 `wtool download-release` + `wtool unpack-release`。
    **发布不再是项目的能力**（引擎统一做，见 `harness/docs/adr/0023`），
    所以表格里没有 download / publish 那两列了。

    每个格子只有四种取值：
      不支持      这个项目没这项能力
      可执行      现在就能跑
      待产出      能力有，但要先把 `__output/` 产出来
      已完成      跑过了
    """
    def _script(name):
        # 脚本住在 scripts/ 下；项目根的老位置仍然认（引擎会给警告）
        return (os.path.isfile(os.path.join(path, "scripts", name))
                or os.path.isfile(os.path.join(path, name)))

    has_build = _script("build.sh")

    acts = st.get("actions") or {}
    built = "build" in acts

    out = {}

    if has_build:
        out["build"] = LBL_DONE if built else LBL_CAN
    else:
        out["build"] = LBL_NONE

    # install：能力来自 wtool.xml 的 link/env，或项目自己的 scripts/install.sh
    has_script = _script("install.sh")
    errors, entries = [], []
    wf = os.path.join(path, "wtool.xml")
    if os.path.isfile(wf):
        _m, entries = parse_manifest(wf, path, errors)
    declarative = bool({e.kind for e in entries} & {"link", "env"})

    if not (has_script or declarative):
        out["install"] = LBL_NONE
    elif st.get("installed"):
        out["install"] = LBL_DONE
    elif has_build and not _has_output(path):
        # 判据和 `wtool install` 一致：**看磁盘**，不看"做过没有"。
        # 有 build.sh 就必须先有 __output/，否则装出来是半成品。
        out["install"] = LBL_TODO
    else:
        out["install"] = LBL_CAN

    return out


def _has_output(path):
    """`<项目>/__output/` 里有没有东西（和 cmd_install 的判据同一件事）。"""
    out = os.path.join(path, DIR_OUT)
    try:
        with os.scandir(out) as it:
            for _ in it:
                return True
    except OSError:
        return False
    return False


def project_caps(path, pub):
    """兼容旧调用：只回答"有没有能力"，不看状态。"""
    st = {"actions": {}, "installed": False, "published": False}
    states = pipeline_states(path, pub, st)
    return {k: ("none" if v == LBL_NONE else "script")
            for k, v in states.items()}


def _box(headers, rows, aligns=None):
    """带表框的小表格。格子里的 ANSI 转义不占宽度，CJK 占两格，都得算对。

    表头允许是**多行**（list）—— 长列名折两行，免得把表撑得太宽（见 DASH_COLS）。
    """
    headers = [h if isinstance(h, (list, tuple)) else [h] for h in headers]
    n = len(headers)
    widths = [max([_width(_strip_ansi(x)) for x in h] or [0]) for h in headers]
    for r in rows:
        for i in range(n):
            w = _width(_strip_ansi(r[i] if i < len(r) else ""))
            if w > widths[i]:
                widths[i] = w

    def _row(cells):
        out = ["\u2502"]
        for i, w in enumerate(widths):
            c = cells[i] if i < len(cells) else ""
            pad = " " * (w - _width(_strip_ansi(c)))
            a = aligns[i] if aligns and i < len(aligns) else "l"
            if a == "r":
                body = pad + c
            elif a == "c":
                left = " " * ((w - _width(_strip_ansi(c))) // 2)
                body = left + c + (" " * (w - _width(_strip_ansi(c)) - len(left)))
            else:
                body = c + pad
            out.append(" " + body + " \u2502")
        return "".join(out)

    def _rule(l, m, r):
        return l + m.join("\u2500" * (w + 2) for w in widths) + r

    out = [_rule("\u250c", "\u252c", "\u2510")]
    # 表头可能不止一行：每一行都按同样的列宽铺出来
    for _i in range(max(len(h) for h in headers)):
        out.append(_row([h[_i] if _i < len(h) else "" for h in headers]))
    out.append(_rule("\u251c", "\u253c", "\u2524"))
    for r in rows:
        out.append(_row(r))
    out.append(_rule("\u2514", "\u2534", "\u2518"))
    return out


def _clip(text, limit):
    """按显示宽度截断（给"说明"列用）：超了加一个省略号。"""
    text = text or ""
    if _width(text) <= limit:
        return text
    out, w = "", 0
    for ch in text:
        cw = _width(ch)
        if w + cw > limit - 1:
            break
        out += ch
        w += cw
    return out + "\u2026"


def _manifest_entries(path):
    """解析项目清单，返回 (meta, entries)；没有 wtool.xml 就 (None, [])。"""
    wf = os.path.join(path, "wtool.xml")
    if not os.path.isfile(wf):
        return None, []
    errors = []
    meta, entries = parse_manifest(wf, path, errors)
    return meta, entries


def _layer_unpacked(path):
    """`unpack-layer` 落地时会写 OWNED.tsv（每层一份）—— 拿它当"解过"的证据。"""
    root = os.path.join(path, DIR_OUT)
    for _dirpath, _dirs, files in os.walk(root):
        if "OWNED.tsv" in files:
            return True
    return False


def _layer_layouts(path):
    """`__layer/<target>/index.json` 有几个（>0 说明这台机器上已经有层了）。"""
    root = os.path.join(path, DIR_LAYER)
    n = 0
    try:
        for name in os.listdir(root):
            if os.path.isfile(os.path.join(root, name, "index.json")):
                n += 1
    except OSError:
        return 0
    return n


def sudo_state():
    """这台机器上"能不能提权"——**每次渲染都现探**（用户 2026-10-04 要求：
    权限可能刚加上，别缓存）。返回 root / nopass / askpass / none。

    规则和 `install-env.sh` 的 `env_sudo_state()` **必须一致**（两处实现、
    一个测试守着，见 ADR-0035）：
      root     本来就是 root
      nopass   `sudo -n true` 成立（免密、或凭证还在缓存里）
      askpass  有 sudo，但要密码 —— 命令能跑（会问密码），所以表格里照样列
      none     没有 sudo（或者 WTOOL_SUDO=never）—— 表格里就不列 sudo 那两列
    """
    if os.geteuid() == 0:
        return "root"
    _want = (os.environ.get("WTOOL_SUDO") or "auto").lower()
    if _want in ("never", "no", "off"):
        return "none"
    # 强制"就当有 sudo"：给测试和特殊环境用（`WTOOL_SUDO=yes`）
    if _want in ("yes", "always", "force", "on"):
        return "nopass"
    if not shutil.which("sudo"):
        return "none"
    def _run(args):
        try:
            return subprocess.run(args, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=5).returncode
        except (OSError, subprocess.SubprocessError):
            return 1
    if _run(["sudo", "-n", "true"]) == 0:
        return "nopass"
    # 要密码的那些人：**先看组**（标准配置就是靠组给权限）。
    #   ⚠️ 别指望 `sudo -n -l`：标准 Ubuntu 上它直接 `sudo: a password is required`，
    #   于是"在 sudo 组、但要密码"的人会被误判成没有 sudo（实测踩过）。
    try:
        _groups = subprocess.run(["id", "-nG"], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=5,
                                 text=True).stdout.split()
    except (OSError, subprocess.SubprocessError):
        _groups = []
    if "sudo" in _groups or "wheel" in _groups:
        return "askpass"
    # 组里没有，但有些配置允许 `sudo -l` 直接列出规则 —— 那也算有
    if _run(["sudo", "-n", "-l"]) == 0:
        return "askpass"
    return "none"


def command_states(path, pub, st, state_dir):
    """看板第 1 段：**每个项目能跑哪些引擎命令、现在到哪一步**。

    列就是引擎里逐项目的那几条命令（不是项目脚本的能力 —— 那是 ADR-023 管的事）：

      build            wtool build
      install          wtool install
      uninstall        wtool uninstall          （装过才可撤，没装就是"未安装"）
      sudo             wtool sudo-install
      sudo-uninstall   wtool sudo-uninstall     （和 sudo 成对看）
      pack             wtool pack-release
      publish          wtool publish-release
      download         wtool download-release
      layer            wtool unpack-layer / push-layer / pull-layer

    格子取值：不支持 / 可执行 / 待产出 / 已完成 / 未发布 / 未安装（都定义在 LBL_*）。
    """
    def _script(name):
        return (os.path.isfile(os.path.join(path, "scripts", name))
                or os.path.isfile(os.path.join(path, name)))

    _meta, entries = _manifest_entries(path)
    kinds = {e.kind for e in entries}
    acts = st.get("actions") or {}
    out = {}

    has_build = _script("build.sh") or os.path.isfile(
        os.path.join(path, "build", "layers.tsv"))

    # build
    if not has_build:
        out["build"] = LBL_NONE
    elif "build" in acts:
        out["build"] = LBL_DONE
    else:
        out["build"] = LBL_CAN

    # install：和 `wtool install` 的判据同一件事（声明面 + __output/ 在不在）
    if not (_script("install.sh") or bool(kinds & {"link", "env"})):
        out["install"] = LBL_NONE
    elif st.get("installed"):
        out["install"] = LBL_DONE
    elif has_build and not _has_output(path):
        out["install"] = LBL_TODO
    else:
        out["install"] = LBL_CAN

    # uninstall：和 install 成对 —— 装过才可撤（用户 2026-10-04 要求）
    if out["install"] == LBL_NONE:
        out["uninstall"] = LBL_NONE
    elif st.get("installed"):
        out["uninstall"] = LBL_CAN
    else:
        out["uninstall"] = LBL_NOTINST

    # sudo-install：清单里得有系统层声明（sysfile / source / task），
    # 而且这台机器上得**真的能提权**（没有 sudo 就别装作能跑）
    _sudo_done = bool(st.get("provisioned") or os.path.isfile(
        os.path.join(state_dir, st["id"], "apt.tsv")))
    if not (kinds & {"sysfile", "source", "task"}):
        out["sudo"] = LBL_NONE
    elif st.get("no_sudo"):
        out["sudo"] = LBL_NONE
    elif _sudo_done:
        out["sudo"] = LBL_DONE
    else:
        out["sudo"] = LBL_CAN

    # sudo-uninstall：和 sudo-install 成对
    if out["sudo"] == LBL_NONE or st.get("no_sudo"):
        out["sudo-uninstall"] = LBL_NONE
    elif _sudo_done:
        out["sudo-uninstall"] = LBL_CAN
    else:
        out["sudo-uninstall"] = LBL_NOTINST

    # pack-release：源码包谁都能打；有 build 能力的要等 __output/
    if os.path.isfile(os.path.join(path, DIR_REL, "dist.json")):
        out["pack"] = LBL_DONE
    elif has_build and not _has_output(path):
        out["pack"] = LBL_TODO
    else:
        out["pack"] = LBL_CAN

    # publish-release：<publish kind="none"/> 的项目不发布
    if (pub or {}).get("kind") == "none":
        out["publish"] = LBL_NONE
    elif st.get("published"):
        out["publish"] = LBL_DONE
    else:
        out["publish"] = LBL_CAN

    # download-release：要仓库里**提交了** scripts/release.json 才有东西可下
    if not os.path.isfile(os.path.join(path, "scripts", "release.json")):
        out["download"] = (LBL_NONE if (pub or {}).get("kind") == "none"
                           else LBL_UNPUB)
    elif st.get("artifact_source") == "download":
        out["download"] = LBL_DONE
    else:
        out["download"] = LBL_CAN

    # layer-*：只有声明了 build/layers.tsv 的项目才有层。
    # 三条命令**各占一列**（用户 2026-10-04：一列一命令，别把三条塞一列）：
    #   unpack-layer  把 __layer/ 里的层解成安装产物 → 有层就是"可执行"，解过是"已完成"
    #   push-layer    把层推到镜像仓库          → 有层才谈得上推
    #   pull-layer    从镜像仓库拉层            → 有层能力就行（拉下来会覆盖 __layer/）
    _has_layers = os.path.isfile(os.path.join(path, "build", "layers.tsv"))
    _n_layouts = _layer_layouts(path) if _has_layers else 0
    if not _has_layers:
        out["unpack-layer"] = out["push-layer"] = out["pull-layer"] = LBL_NONE
    else:
        # ⚠️ 这三条命令**不写 journal**（实测：unpack/push/pull 跑完只在屏幕上说话），
        #    所以"已完成"只能靠**文件**判：unpack 落地会写 OWNED.tsv。
        #    推没推过、拉没拉过，本机没有记录 —— 那两列最高只到"可执行"，
        #    想知道真状态得去问镜像仓库（别在这儿编一个"已完成"）。
        out["unpack-layer"] = (LBL_DONE if _layer_unpacked(path)
                               else (LBL_CAN if _n_layouts else LBL_TODO))
        out["push-layer"] = LBL_CAN if _n_layouts else LBL_TODO
        out["pull-layer"] = LBL_CAN

    return out


# 列顺序：install / uninstall 成对、sudo / sudo-uninstall 成对（用户 2026-10-04 要求：
# "装之前 install 是可执行、uninstall 是未安装；装完之后 install 变已完成、
#  uninstall 变可执行，sudo 同此逻辑"）
# 看板第 1 段的列：**(键, 表头行)**。表头行可以是一行，也可以是**折成两行**的
# 几行 —— 用户 2026-10-04 的两条要求：
#   ① 一列只对应**一个**命令（原来 `layer` 一列塞了 unpack/push/pull 三条，
#      看的人分不清那个"已完成"指的是哪条）；
#   ② 名字太长就把列宽撑开（`uninstall` 9 格、`download` 8 格），
#      所以长名字**折成两行**，每行不超过 6 个字符。
# 折法的规矩：**从上往下读就是那个命令名**（`un` + `install` = uninstall，
# `unpack` + `layer` = unpack-layer），优先在 `-` 处断。
# 列键 → 对应的**引擎命令名**（`wtool status` 要逐列写出来）。
# 一列一命令，这张表就是那份对应关系（用户 2026-10-04 要求）。
WT_CMD_OF = {"build": "wtool build", "install": "wtool install",
             "uninstall": "wtool uninstall", "sudo": "wtool sudo-install",
             "sudo-uninstall": "wtool sudo-uninstall", "pack": "wtool pack-release",
             "publish": "wtool publish-release", "download": "wtool download-release",
             "unpack-layer": "wtool unpack-layer", "push-layer": "wtool push-layer",
             "pull-layer": "wtool pull-layer"}

# 表头用**中文**，具体命令写在表格下边的对照里（用户 2026-10-04 给的对照表）。
DASH_COLS = [("build", ["构建"]),
             ("install", ["安装"]),
             ("uninstall", ["卸载"]),
             ("sudo", ["sudo安装"]),
             ("sudo-uninstall", ["sudo卸载"]),
             ("pack", ["做gz包"]),
             ("publish", ["发布包"]),
             ("download", ["下gz包"]),
             ("unpack-layer", ["解容器层"]),
             ("push-layer", ["推容器层"]),
             ("pull-layer", ["拉容器层"])]


def _hdr(title):
    """一段的标题行。长度固定，免得跟着表格宽度变来变去。"""
    bar = "\u2500" * 72
    return ["", bar, " " + title, bar]


def _dash_cols(projects):
    """这一屏要摆哪几列：没有 sudo 的机器上，`sudo` / `sudo-un` 两列直接不列
    （省宽度，也不误导 —— 用户 2026-10-04 要求）。"""
    if projects and all(p.get("no_sudo") for p in projects):
        return [(k, h) for k, h in DASH_COLS if k not in ("sudo", "sudo-uninstall")]
    return list(DASH_COLS)


def _status_evidence(path, st, pub, state_dir):
    """「这一格是从哪看出来的」—— 逐列给依据（用户 2026-10-04：把状态做成可查询的）。"""
    def _has(rel):
        return os.path.exists(os.path.join(path, rel))

    out = os.path.join(path, DIR_OUT)
    n_out = len(os.listdir(out)) if os.path.isdir(out) else 0
    n_journal = sum(1 for _ in _read_tsv(os.path.join(state_dir, st["id"], "journal.tsv")))
    n_pub = sum(1 for _ in _read_tsv(os.path.join(state_dir, st["id"], "publish.tsv")))
    n_targets = _layer_layouts(path)
    n_unpacked = 0
    if os.path.isdir(out):
        for _dp, _ds, _fs in os.walk(out):
            if "OWNED.tsv" in _fs:
                n_unpacked += 1
    rel_json = os.path.join(path, "scripts", "release.json")
    return {
        "build": "有 scripts/build.sh；%s" % (
            "%s 里有 %d 项" % (DIR_OUT + "/", n_out) if n_out else "%s/ 还没有" % DIR_OUT),
        "install": "有 scripts/install.sh；安装记录 %d 条" % n_journal,
        "uninstall": ("安装记录 %d 条 → 撤得掉" % n_journal) if n_journal
                     else "安装记录 0 条 → 现在没什么可撤的",
        "sudo": ("wtool.xml 声明了系统层（sysfile/source/task）；已装 %d 个文件"
                 % st.get("sysfiles", 0)) if st.get("markers") or st.get("sysfiles")
                else "wtool.xml 里没有系统层声明（sysfile/source/task）",
        "sudo-uninstall": "已装系统文件 %d 个" % st.get("sysfiles", 0),
        "pack": "%s 里有 %d 项" % (DIR_OUT + "/", n_out) if n_out else "%s/ 还没有" % DIR_OUT,
        "publish": "发布记录 %d 条" % n_pub if n_pub else "发布记录 0 条（还没发过）",
        "download": ("仓库里有 scripts/release.json（发布信息）" if os.path.isfile(rel_json)
                     else "仓库里没有 scripts/release.json → 还没发布过，没东西可下"),
        "unpack-layer": ("build/layers.tsv 在；%s/ 有 %d 个 target；解出来 %d 份 OWNED.tsv"
                         % (DIR_LAYER, n_targets, n_unpacked) if _has("build/layers.tsv")
                         else "没有 build/layers.tsv → 这个项目没有层"),
        "push-layer": ("build/layers.tsv 在；%s/ 有 %d 个 target（推没推过本机不记，"
                       "去镜像仓库看）" % (DIR_LAYER, n_targets) if _has("build/layers.tsv")
                       else "没有 build/layers.tsv → 这个项目没有层"),
        "pull-layer": ("build/layers.tsv 在 → 可以从镜像仓库拉（拉下来会覆盖 %s/）" % DIR_LAYER
                       if _has("build/layers.tsv") else "没有 build/layers.tsv → 这个项目没有层"),
    }


def project_status(root, state_dir, ident):
    """`wtool status <项目>`：逐列给 **状态 + 对应的命令 + 这一格的依据**。

    用户 2026-10-04：表格里一列只该对应一个命令，而且"状态也要有专门的查询方法" ——
    这张表就是那个查询：看板给你一眼，status 给你"为什么"和"接下来敲哪条"。
    """
    projs = scan_projects(root, manifests_only=True)
    hit = None
    for prio, pid, path, pub in projs:
        if ident in (pid, path) or pid.endswith("/" + ident.rstrip("/")):
            hit = (prio, pid, path, pub)
            break
    if hit is None:
        return ["找不到项目「%s」。现有：%s" % (ident, " ".join(p[1] for p in projs))], 2
    prio, pid, path, pub = hit
    no_sudo = sudo_state() == "none"
    st = dict(project_state(path, state_dir, root=root))
    st["no_sudo"] = no_sudo
    cmds = command_states(path, pub, st, state_dir)
    ev = _status_evidence(path, st, pub, state_dir)
    rows = []
    for key, hdr in _dash_cols([st]):
        # 列名用 key（折起来读是 uninstall，摊开还是 uninstall）；命令单独一列
        rows.append([hdr[0], cmds[key], WT_CMD_OF.get(key, "-"), ev.get(key, "")])
    out = ["", "项目 %s（prio %s）  %s" % (pid, prio, path),
           "  一列一个命令；状态就是看板里那一格，依据 = 「这一格是怎么看出来的」。", ""]
    out += _box([["列"], ["状态"], ["对应命令"], ["依据（这一格是怎么看出来的）"]], rows,
                aligns=["l", "c", "l", "l"])
    out += ["",
            "  · 想知道某条命令**到底会做什么**：wtool <命令> %s --dry-run（不动手，只出计划）" % pid,
            "  · 状态只有六种：不支持 / 可执行 / 待产出 / 已完成 / 未发布 / 未安装（和看板同一套）",
            "  · push-layer / pull-layer 的「推过没、拉过没」本机**没有记录**（那两条命令不写 journal）——",
            "    本机只能告诉你「能不能推」；真状态去镜像仓库看。"]
    return out, 0


def _section_command_table(projects, color):
    cols = _dash_cols(projects)
    rows = []
    for p in projects:
        cells = [p["id"], str(p["prio"])]
        for key, _h in cols:
            cells.append(p["cmds"][key])
        rows.append(cells)
    headers = [["项目"], ["prio"]] + [h for _k, h in cols]
    plain = [[_strip_ansi(c) for c in r] for r in rows]
    colored = [r[:2] + [_state_cell(v, color) for v in r[2:]] for r in rows]
    widths = [max(_width(x) for x in h) for h in headers]   # 表头可能折成两行
    for r in plain:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], _width(c))
    body = []
    for pr, cl in zip(plain, colored):
        body.append([cl[i] + " " * (widths[i] - _width(pr[i])) for i in range(len(cl))])
    return _box(headers, body, aligns=["l", "r"] + ["c"] * len(cols))


def _section_install(projects, verbose):
    rows = []
    for p in projects:
        if p["cmds"]["install"] == LBL_NONE:
            continue
        if p["installed"]:
            state = LBL_DONE
        elif p["cmds"]["install"] == LBL_TODO:
            state = LBL_TODO
        else:
            state = LBL_CAN
        if p["cmds"]["install"] == LBL_TODO:
            what = "要先产出 __output/：wtool build，或 wtool download-release + wtool unpack-release"
        else:
            bits = []
            if p["n_link"]:
                bits.append("%d 条软链" % p["n_link"])
            if p["n_env"]:
                bits.append("%d 个 shell 块" % p["n_env"])
            if p["has_install_script"]:
                bits.append("scripts/install.sh")
            what = "、".join(bits) if bits else "（没声明要装什么）"
            if p["installed"] and verbose and p["installed_at"]:
                what += "；装过（%s）" % p["installed_at"]
        rows.append([p["id"], state, _clip(what, 60)])
    return rows


def _section_sudo(projects, verbose):
    rows = []
    for p in projects:
        if p["cmds"]["sudo"] == LBL_NONE:
            continue
        state = LBL_DONE if p["cmds"]["sudo"] == LBL_DONE else LBL_CAN
        bits = []
        if p["n_sysfile"]:
            bits.append("%d 个系统文件" % p["n_sysfile"])
        if p["n_task"]:
            d = "、".join(_clip(x, 18) for x in p["task_descs"][:2])
            bits.append("%d 个任务%s" % (p["n_task"], ("（%s）" % d) if d else ""))
        if p["n_source"]:
            bits.append("%d 个源码树" % p["n_source"])
        what = "、".join(bits) if bits else "（没声明要装什么）"
        if verbose and p["sudo_when"]:
            what += "；跑过（%s）" % p["sudo_when"]
        rows.append([p["id"], state, _clip(what, 60)])
    return rows


def _section_bootstrap(projects, verbose):
    rows = []
    i = 0
    for p in projects:
        if p["cmds"]["build"] == LBL_CAN and not _has_output(p["path"]):
            state, what = "跳过", "要先产出 __output/（wtool build 或 download-release + unpack-release）"
        elif p["cmds"]["install"] == LBL_NONE:
            i += 1
            state, what = "会跑", "没声明要装什么 —— 只登记一条中转软链（install 对它是空操作）"
        elif p["installed"]:
            i += 1
            state, what = "重装", "已装过；重装是幂等的（没变就不动）"
        else:
            i += 1
            state, what = "会装", "本机用户层（不要 sudo、不联网）"
        rows.append([str(i) if state != "跳过" else "-", p["id"], state, _clip(what, 58)])
    return rows


def _section_sudo_bootstrap(projects, verbose):
    rows = []
    i = 0
    for p in projects:
        if p["cmds"]["sudo"] == LBL_NONE:
            continue
        i += 1
        state = "重跑" if p["cmds"]["sudo"] == LBL_DONE else "会跑"
        what = "系统层：apt 包 / /etc 下的文件 / 任务（可能要 sudo、要联网）"
        if state == "重跑":
            what = "跑过；重跑靠 marker 幂等"
        rows.append([str(i), p["id"], state, _clip(what, 58)])
    return rows


INSTALL_PIC = [
    "  install",
    "  -------",
    "      route 1:  wtool build ----------+",
    "                                      +-->  __output/  --+",
    "      route 2:  wtool unpack-release -+                  |",
    "                                                         v",
    "                                              wtool install     (never sudo / never network)",
    "                                                         |",
    "                                                         v",
    "                                              ~/.wtool/         (mirror of $HOME)",
    "                                                         |",
    "                               read wtool.xml -----------+---->  symlinks in $HOME",
    "                                                                 $HOME/x  -->  ~/.wtool/x",
]

RELEASE_PIC = [
    "  release",
    "  -------",
    "      __output/  --( wtool pack-release )-->  __release/  --( wtool publish-release )-->  GitHub Release",
    "                                                   ^                                            |",
    "                                                   +-------( wtool download-release )-----------+",
    "                                                   |",
    "                                                   +--( wtool unpack-release )-->  __output/",
]

README_TEXT = [
    "  流水线：产出 → install，前面的没做后面的跑不起来。",
    "  产出有两条路：wtool build；或者 wtool download-release（下到 __release/）",
    "                + wtool unpack-release（解到 __output/）。",
    "  注意 download-release 的落点是 __release/，**不是** __output/；",
    "  它下完还要再跑一次 wtool unpack-release 才变成能 install 的产物。",
    "  前置没做时 install 会直接报错告诉你去跑哪条，不会替你跑。",
    "  （发布和下载不是「项目能力」，是引擎统一做的 —— 见 harness/docs/adr/0023。）",
]


def render_dashboard(root, state_dir, verbose=False, color=None, brief=False):
    """看板：五段表格 + 一段说明 + 两张图。返回 (文本行列表, 项目列表)。

    段（2026-09-29 用户要求：`wtool` 第一屏要把**所有逐项目的命令**摆出来，
    而不是只有 build / install 两列）：

      1. 能力表     每个项目能跑哪些命令、走到哪一步了
      2. install    `wtool install` 能装哪些项目、装过没
      3. sudo-install  `wtool sudo-install` 能装哪些项目、跑过没、会装什么
      4. bootstrap  `wtool bootstrap` 这次会装哪些、按什么顺序、谁会被跳过
      5. sudo-bootstrap  `wtool sudo-bootstrap` 这次会跑哪些
      然后才是流水线说明和两张图（安装 / 发布）

    brief=True 只打第 1 段 + 图例 + 汇总行（给 `wtool doctor` 和 bootstrap 末尾用，
    那里不需要再看一遍计划）。
    """
    state_dir = os.path.abspath(state_dir)
    if color is None:
        color = sys.stdout.isatty()

    # sudo 现探一次（每次跑 wtool 都探，用户可能刚被加进 sudoers）
    _sudo = sudo_state()
    no_sudo = _sudo == "none"

    projects = []
    for prio, pid, path, pub in scan_projects(root, manifests_only=True):
        st = project_state(path, state_dir, root=root)
        st["prio"] = prio
        st["path"] = path
        st["pub"] = pub
        st["no_sudo"] = no_sudo
        st["sudo_state"] = _sudo
        st["cmds"] = command_states(path, pub, st, state_dir)
        st["cells"] = pipeline_states(path, pub, st)

        _meta, entries = _manifest_entries(path)
        st["n_link"] = sum(1 for e in entries if e.kind == "link")
        st["n_env"] = sum(1 for e in entries if e.kind == "env")
        st["n_sysfile"] = sum(1 for e in entries if e.kind == "sysfile")
        st["n_source"] = sum(1 for e in entries if e.kind == "source")
        st["n_task"] = sum(1 for e in entries if e.kind == "task")
        st["task_descs"] = [e.desc or e.src or "-" for e in entries if e.kind == "task"]
        st["has_install_script"] = (
            os.path.isfile(os.path.join(path, "scripts", "install.sh"))
            or os.path.isfile(os.path.join(path, "install.sh")))

        # 装过 / sudo 跑过的时间：查得到就写出来
        st["installed_at"] = ""
        for row in _read_tsv(os.path.join(state_dir, st["id"], "meta.tsv")):
            if len(row) >= 2 and row[0] == "installed_at":
                st["installed_at"] = row[1][:16]
        st["sudo_when"] = st["actions"].get("provision", "")[:16]
        projects.append(st)

    projects.sort(key=lambda p: (p["prio"], p["id"]))

    out = []
    out += _hdr("1. 每个项目能跑哪些命令（引擎里逐项目的那些）")
    out += _section_command_table(projects, color)
    out.append("")
    # 列名就是引擎命令，**一条都不省**（用户 2026-10-04 要求：
    # "这里不要省略 pull-layer 和 push-layer"）。没有 sudo 的机器少两列 ——
    # 那两列本来也跑不了（用户要求：没权限就别列）。
    out.append("  列名 → 对应的命令（表格里的中文名，下边都写着它到底是哪条）：")
    if no_sudo:
        out.append("      ⚠️ 这台机器上没有 sudo → 少列了 sudo / sudo-un 两列。")
        out.append("         拿到 sudo 权限之后重跑 wtool 就会自动出现（每次都会现探）。")
    for _key, _hlines in DASH_COLS:
        if no_sudo and _key in ("sudo", "sudo-uninstall"):
            continue
        _lbl = _hlines[0]
        _pad = " " * max(0, 16 - _width(_lbl))
        out.append("      %s%s%s" % (_lbl, _pad, WT_CMD_OF[_key]))
    out.append("      解gz包        wtool unpack-release     （装东西那条路上的一步：__release/ → __output/）")
    out.append("  想知道某一格**是怎么算出来的**：wtool status <项目>（逐列给状态 + 依据 + 该敲哪条命令）")
    out.append("  格子：%s 这个项目没这项能力   %s 现在就能跑   %s 要先产出 __output/   %s 跑过了   %s 还没发布过   %s 还没装（撤不了）"
               % (LBL_NONE, LBL_CAN, LBL_TODO, LBL_DONE, LBL_UNPUB, LBL_NOTINST))
    out.append("")
    out.append(table_summary(projects))

    if brief:
        return out, projects

    out += _hdr("2. wtool install —— 能装哪些项目、装过没")
    rows = _section_install(projects, verbose)
    if rows:
        out += _box(["项目", "状态", "会做什么"], rows, aligns=["l", "c", "l"])
    _none = [p["id"] for p in projects if p["cmds"]["install"] == LBL_NONE]
    out.append("  没有列出来的项目 = 没声明要装什么（既没有 scripts/install.sh，也没有 <link>/<zshrc>）：%s"
               % ("、".join(_none) if _none else "（无）"))

    out += _hdr("3. wtool sudo-install —— 能装哪些项目、跑过没")
    rows = _section_sudo(projects, verbose)
    if rows:
        out += _box(["项目", "状态", "会装什么"], rows, aligns=["l", "c", "l"])
    else:
        out.append("  （没有项目声明系统层）")
    out.append("  提示：这一步可能要 sudo、要联网；和 wtool install 是两条独立的路")

    out += _hdr("4. wtool bootstrap —— 这次会装哪些、什么顺序")
    out += _box(["#", "项目", "这次", "说明"], _section_bootstrap(projects, verbose),
                aligns=["r", "l", "c", "l"])
    out.append("  bootstrap = 逐个 wtool install（不做系统层、不联网）；需要先产出的会跳过")

    out += _hdr("5. wtool sudo-bootstrap —— 这次会跑哪些")
    rows = _section_sudo_bootstrap(projects, verbose)
    if rows:
        out += _box(["#", "项目", "这次", "说明"], rows, aligns=["r", "l", "c", "l"])
    else:
        out.append("  （没有项目声明系统层）")
    out.append("  sudo-bootstrap = 逐个 wtool sudo-install")

    if verbose:
        out += _hdr("6. 明细（装过什么时候、产物从哪来、发布过没）")
        for p in projects:
            bits = []
            if p["installed"]:
                bits.append("装过%s" % ("（%s）" % p["installed_at"] if p["installed_at"] else ""))
            if p["artifact_source"]:
                bits.append("产物来自 %s" % p["artifact_source"])
            if p["cmds"]["sudo"] == LBL_DONE:
                d = []
                if p["markers"]:
                    d.append("%d 个 marker" % p["markers"])
                if p["sysfiles"]:
                    d.append("%d 个系统文件" % p["sysfiles"])
                bits.append("系统层跑过" + ("（%s）" % "、".join(d) if d else ""))
            if (p["pub"] or {}).get("kind") == "none":
                bits.append("不发布")
            elif p["published"]:
                bits.append("发布过")
            if os.path.isfile(os.path.join(p["path"], "scripts", "release.json")):
                bits.append("有下载声明")
            out.append("  %-22s %s" % (p["id"], "；".join(bits) if bits else "（还没有动作）"))

    out += [""]
    out += README_TEXT
    out += [""]
    out += INSTALL_PIC
    out += [""]
    out += RELEASE_PIC
    return out, projects


def table_summary(projects):
    """一句话汇总，给 wtool doctor 用。"""
    n = len(projects)
    installed = sum(1 for p in projects if p["installed"])
    pub = sum(1 for p in projects if p["published"])
    todo_pub = sum(1 for p in projects
                   if p["pub"]["kind"] != "none" and not p["published"])
    # 注意用 cells（pipeline_states 的结果），不是已经不存在的 caps。
    # 这里崩过一次：换数据结构时只改了 render_table，忘了这里，
    # 而 wtool doctor 走的正是 --summary 这条路。
    todo_build = sum(1 for p in projects if p["cells"]["build"] == LBL_CAN)
    todo_inst = sum(1 for p in projects if p["cells"]["install"] == LBL_CAN)
    return ("共 %d 个项目：已安装 %d（待装 %d），已发布 %d（待发 %d），待构建 %d"
            % (n, installed, todo_inst, pub, todo_pub, todo_build))


# --------------------------------------------------------------------------
# 环境变量汇总
#
# 每个项目的 env 块单独存在 $WTOOL_STATE/<id>/env.<shell>，
# 这里把它们按 (priority, id) 拼成一个文件，再由用户 rc 里的**唯一一个**
# loader 块 source 进去。
#
# 为什么不让每个项目往用户的 rc 里各写一段：
#   * 用户 rc 会被 N 个项目改来改去，脏且危险（要在别人的文件里做排序插入）
#   * 想彻底撤销得逐个块删，漏一个就留垃圾
# 现在用户的 rc 里只有一个块，删掉它 wtool 对环境的影响就没了。
# --------------------------------------------------------------------------
LOADER_BEGIN = "# >>> wtool >>>"
LOADER_END = "# <<< wtool <<<"
LOADER_OLD_RE = re.compile(r"^# >>> wtool:(\S+) .* >>>\s*$")

AGG_HEADER = """# 由 wtool 生成 —— 不要手改，改了下次 install/uninstall 会被覆盖。
#
# 每个项目的环境变量按 priority 排在这里；要改内容请去改各自项目里的
# env 文件（见每段开头的 # >>> wtool:<项目> 注释）。
#
# 这个文件被 ~/.{shell}rc 里的一小段托管块 source。想彻底去掉 wtool
# 对环境的影响，删掉那里的 # >>> wtool >>> 块即可。
"""


def _loader_block(shell):
    return [
        LOADER_BEGIN,
        "# wtool 装的东西都从这里生效。所有项目的环境变量都收在下面这个文件里，",
        "# 这里只是把它 source 进来 —— 想彻底去掉 wtool 的影响，删掉这个块即可。",
        '[ -f "$HOME/.wtool/.%src" ] && . "$HOME/.wtool/.%src"' % (shell, shell),
        LOADER_END,
    ]


def collect_env_blocks(state, shell, exclude=""):
    """扫出所有项目的 env 块，按 (priority, id) 排序。"""
    state = os.path.abspath(state)
    found = []
    if not os.path.isdir(state):
        return found
    for dirpath, dirnames, filenames in os.walk(state):
        name = "env.%s" % shell
        if name not in filenames:
            continue
        pid = os.path.relpath(dirpath, state)
        if exclude and (pid == exclude or pid.startswith(exclude + "/")):
            continue
        prio = DEFAULT_PRIORITY
        meta = os.path.join(dirpath, "meta.tsv")
        text = read_text(meta)
        if text:
            for line in text.split("\n"):
                if line.startswith("priority\t"):
                    try:
                        prio = int(line.split("\t", 1)[1])
                    except ValueError:
                        pass
        found.append((prio, pid, read_text(os.path.join(dirpath, name)) or ""))
    found.sort(key=lambda t: (t[0], t[1]))
    return found


def render_env(home, state, shell, exclude=""):
    """算出两个文件的新内容：用户的 rc，和汇总文件。

    返回 (rc_path, rc_text|None, agg_path, agg_text|None)
    None 表示这个文件不该存在（要删掉）。
    """
    home = os.path.abspath(home)
    rc_path = os.path.join(home, ".%src" % shell)
    agg_path = os.path.join(home, ".wtool", ".%src" % shell)

    blocks = collect_env_blocks(state, shell, exclude=exclude)

    # 汇总文件
    if blocks:
        parts = [AGG_HEADER.format(shell=shell)]
        for _prio, pid, text in blocks:
            parts.append("")
            parts.append(text.rstrip("\n"))
        agg_text = "\n".join(parts).rstrip("\n") + "\n"
    else:
        agg_text = None

    # 用户的 rc：先把它里面所有 wtool 的块（老的 per-project 块 + 新的 loader）
    # 全部剥掉，再按需要补上 loader。这样迁移是自动的，也不会堆积。
    old = read_text(rc_path)
    if old is None and agg_text is None:
        return rc_path, None, agg_path, None

    lines = (old or "").split("\n")
    kept, skipping = [], False
    for line in lines:
        stripped = line.strip()
        if stripped == LOADER_BEGIN or LOADER_OLD_RE.match(stripped):
            skipping = True
            continue
        if skipping:
            if stripped == LOADER_END or re.match(r"^# <<< wtool:\S+ <<<\s*$", stripped):
                skipping = False
            continue
        kept.append(line)

    while kept and not kept[-1].strip():
        kept.pop()

    if agg_text is None:
        # 一个项目都没装：rc 恢复成剥掉块之后的样子
        new_rc = "\n".join(kept)
        new_rc = new_rc + "\n" if new_rc else ""
        if old is None:
            return rc_path, None, agg_path, None
        if new_rc == "":
            return rc_path, None, agg_path, None      # 文件空了就删掉
        return rc_path, new_rc, agg_path, None

    body = "\n".join(kept).rstrip("\n")
    new_rc = (body + "\n\n" if body else "") + "\n".join(_loader_block(shell)) + "\n"
    return rc_path, new_rc, agg_path, agg_text


def plan_env(args, scratch):
    """把 render_env 的结果落成动作行，交给 shell 执行（Python 只算不写）。

    顺带管**唯一一条引擎自己造的全局软链**：`~/usr` → `~/.wtool/usr`。
    它不属于任何项目，一个项目都不剩时随 loader 块一起收走
    （见 harness/architecture.md §8）。
    """
    rows = []
    exclude = getattr(args, "exclude", "") or ""
    for shell in ("zsh", "bash"):
        rc_path, rc_text, agg_path, agg_text = render_env(args.home, args.state,
                                                          shell, exclude=exclude)

        if rc_text is None:
            if os.path.isfile(rc_path):
                rows.append(("remove", "file", rc_path, "-", "-", "-"))
        else:
            old = read_text(rc_path)
            if old != rc_text:
                f = os.path.join(scratch, "env-rc.%s" % shell)
                with open(f, "w", encoding="utf-8", errors="surrogateescape") as fh:
                    fh.write(rc_text)
                rows.append(("write", "file", rc_path, f, sha256_text(rc_text), "-"))

        if agg_text is None:
            if os.path.isfile(agg_path):
                rows.append(("remove", "file", agg_path, "-", "-", "-"))
        else:
            old = read_text(agg_path)
            if old != agg_text:
                f = os.path.join(scratch, "env-agg.%s" % shell)
                with open(f, "w", encoding="utf-8", errors="surrogateescape") as fh:
                    fh.write(agg_text)
                rows.append(("write", "file", agg_path, f, sha256_text(agg_text), "-"))

    rows.extend(plan_usr_link(args.home, args.state, exclude))
    return rows


def _installed_ids(state, exclude="", home=""):
    """state 目录下"还装着"的项目 id。判据是文件，不是内存里的东西。

    `~/usr` 那条引擎自己的登记要跳过：它**不属于任何项目**，但登记表里
    会挂着最后一个装它的项目（wt_plan_exec 的 link 分支会登记）。
    不跳过的话，那个项目卸完它还留着，`~/usr` 就永远收不走（踩过）。
    """
    usr_dest = os.path.join(os.path.abspath(home), "usr") if home else ""
    state = os.path.abspath(state)
    out = []
    if not os.path.isdir(state):
        return out
    for dirpath, _dirnames, filenames in os.walk(state):
        pid = os.path.relpath(dirpath, state)
        if pid == ".":
            continue
        if exclude and (pid == exclude or pid.startswith(exclude + "/")):
            continue
        for name in ("meta.tsv", "env.zsh", "env.bash"):
            if name in filenames:
                out.append(pid)
                break
    # registry 里还有别的项目登记着也算（比如只有 link、没有 env 的项目）
    for row in _read_tsv(os.path.join(state, "registry.tsv")):
        # 引擎自己登记的不算"某个项目还装着"：owner 是 - 的、以及 ~/usr
        if not row or not row[0]:
            continue
        if usr_dest and os.path.abspath(row[0]) == usr_dest:
            continue
        if len(row) >= 2 and row[1] and row[1] not in ("-", "wtool") \
                and row[1] != exclude:
            out.append(row[1])
    return out


def plan_usr_link(home, state, exclude=""):
    """~/usr → ~/.wtool/usr 这条全局软链的动作行。

    有项目装着就保证它在；一个都不剩就收走 —— 但**只删软链，不碰实体**：
    ~/.wtool/usr 里是编译/下载产物，删了就没法卸干净了（那是 uninstall 的事）。
    """
    home = os.path.abspath(home)
    dest = os.path.join(home, "usr")
    target = os.path.join(home, SHADOW_ROOT_NAME, "usr")
    rows = []
    if _installed_ids(state, exclude, home):
        # 刻意**不发 reg 行**：~/usr 不属于任何项目，它的生死归 wt_env_sync。
        # 登记成某个项目的话，那个项目 uninstall 之后 registry 里还留着它，
        # _installed_ids 就会永远认为"还有项目装着"，~/usr 再也收不走（踩过）。
        if not (os.path.islink(dest) and os.path.normpath(os.readlink(dest))
                == os.path.normpath(target)):
            rows.append(("link", "dir", dest, target, "", ""))
    else:
        if os.path.islink(dest) and os.path.normpath(os.readlink(dest)) \
                == os.path.normpath(target):
            rows.append(("unlink", "dir", dest, target, "", ""))
        # 登记表里那条也清掉（link 动作登记过它）
        rows.append(("regdel", "dir", dest, "", "", ""))
    return rows


# --------------------------------------------------------------------------
# 下载链接块
#
# 发布之后要把"没有 git clone 时怎么装"那一节的下载地址刷新掉。
# 这件事必须由脚本做：手工维护的链接一定会过期，而过期的下载链接
# 比没有链接更糟——照着做的人只会得到一个 404。
#
# 生成的是完整可复制的命令，不是光秃秃的 URL 列表：
# 目标读者是"拿到一台干净机器、只想赶紧装上"的人。
# --------------------------------------------------------------------------
DL_BEGIN = "<!-- >>> wtool:downloads >>> -->"
DL_END = "<!-- <<< wtool:downloads <<< -->"


def splice_block(text, begin, end, body):
    """把 text 里 begin/end 之间的内容换成 body。找不到标记就返回 None。"""
    lines = text.split("\n")
    try:
        i = next(k for k, l in enumerate(lines) if l.strip() == begin)
        j = next(k for k, l in enumerate(lines) if l.strip() == end and k > i)
    except StopIteration:
        return None
    return "\n".join(lines[:i + 1] + body.split("\n") + lines[j:])


def render_downloads(rows):
    """rows: [(项目 id, 仓 owner/repo, tag, 资产名, 下载 URL, 字节数)]

    输出一整套可直接粘贴的命令。分 PowerShell 和 bash 两版，
    因为这两种人是真的会在不同机器上照着做的。
    """
    rows = sorted(rows)
    out = []
    out.append("<!-- 这一块由 `wtool publish` 自动重写，不要手改。 -->")
    out.append("")
    if not rows:
        out.append("> 还没有发布过任何项目。在任意一台能访问 GitHub 的机器上跑")
        out.append("> `wtool publish` 之后，这里会自动填上。")
        return "\n".join(out)

    out.append("每个项目的最新发布包都在它自己的 release 页面上。")
    out.append("全部下载并解开之后，你会得到一个完整的工作区目录。")
    out.append("")
    out.append("| 项目 | 版本 | 包 | 大小 |")
    out.append("|---|---|---|---|")
    for pid, repo, tag, name, url, size in rows:
        out.append("| `%s` | [%s](https://github.com/%s/releases/tag/%s) | [%s](%s) | %s |"
                   % (pid, tag, repo, tag, name, url, _human_size(size)))
    out.append("")

    # 下载目录和最终的目录名：解压出来第一层就是 wtool/
    out.append("### bash（Linux / macOS / WSL）")
    out.append("")
    out.append("```bash")
    out.append("mkdir -p ~/self && cd ~/self")
    for _pid, _repo, _tag, name, url, _size in rows:
        out.append('curl -fL -o %s \\\n  %s' % (name, url))
    for _pid, _repo, _tag, name, _url, _size in rows:
        out.append("tar -xf %s" % name)
    out.append("```")
    out.append("")
    out.append("跑完 `~/self/wtool/` 就是一个完整的工作区。")
    out.append("接着 `cd ~/self/wtool && ./bootstrap/install.sh`（第一次要用完整路径，")
    out.append("它会把根目录的 `./install.sh` 等入口补齐，之后就能直接用短的了）。")
    out.append("")

    out.append("### PowerShell（Windows 10 及以上自带 tar）")
    out.append("")
    out.append("```powershell")
    _bs = chr(92)
    out.append('$d = "$HOME%sself"; New-Item -ItemType Directory -Force -Path $d | Out-Null; Set-Location $d' % _bs)
    for _pid, _repo, _tag, name, url, _size in rows:
        out.append('Invoke-WebRequest -Uri "%s" -OutFile "%s"' % (url, name))
    for _pid, _repo, _tag, name, _url, _size in rows:
        out.append("tar -xf %s" % name)
    out.append("```")
    out.append("")
    out.append("跑完 `$HOME%sself%swtool` 就是一个完整的工作区。" % (_bs, _bs))
    return "\n".join(out)


def _human_size(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return ("%d%s" % (n, unit)) if unit == "B" else ("%.1f%s" % (n, unit))
        n /= 1024.0
    return "?"


def update_downloads(doc_path, rows_tsv):
    """把下载块写进文档。rows_tsv 是 shell 侧收集好的 TSV。"""
    rows = []
    for parts in _read_tsv(rows_tsv):
        if len(parts) < 6:
            continue
        rows.append(tuple(parts[:6]))
    try:
        with open(doc_path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise PlanError("读不了文档: %s: %s" % (doc_path, exc))

    body = render_downloads(rows)
    new = splice_block(text, DL_BEGIN, DL_END, body)
    if new is None:
        raise PlanError("文档里找不到下载块标记 %s: %s" % (DL_BEGIN, doc_path))
    sys.stdout.write(new)


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def _repo_manifest_projects(root):
    """从 repo 客户端的 manifest 里读出全部项目路径。

    为什么需要：'没写 wtool.xml 就按源码发布' 这条规则要求知道**完整的项目表**，
    而 wtool 自己扫不出来——没有 wtool.xml 的项目（harness、themes/...）它看不见。
    只有 repo 的 manifest 知道全表。
    """
    repo_dir = os.path.join(root, ".repo")
    merged = os.path.join(repo_dir, "manifest.xml")
    if not os.path.isfile(merged):
        return {}
    manifests_dir = os.path.join(repo_dir, "manifests")

    paths, removed, seen = {}, set(), set()

    def load(path, depth=0):
        if depth > 8 or path in seen:
            return
        seen.add(path)
        try:
            with open(path, encoding="utf-8") as fh:
                root_el = ET.fromstring(fh.read())
        except (OSError, ET.ParseError):
            return
        for el in root_el:
            if el.tag == "include":
                name = el.get("name")
                if name:
                    load(os.path.join(manifests_dir, name), depth + 1)
            elif el.tag == "project":
                p = el.get("path") or el.get("name") or ""
                if p:
                    paths[p.rstrip("/")] = el.get("name") or ""
            elif el.tag == "remove-project":
                n = el.get("name")
                if n:
                    removed.add(n)

    load(merged)
    # remove-project 按 name 匹配
    return {p: n for p, n in paths.items() if n not in removed}


def _dist_marker_projects(root):
    """从 .wtool-dist/*.json 里读出项目表。

    每个源码包都会在 wtool/.wtool-dist/ 下带一个标记，记着 project / repo /
    commit。解压出来一个工作区之后，这些标记合起来就是一份完整的项目清单——
    而这时既没有 .repo（没有 manifest 可查），没有 wtool.xml 的项目
    （harness、themes/...）也扫不出来。标记正好补上这一环。
    """
    d = os.path.join(root, ".wtool-dist")
    out = {}
    if not os.path.isdir(d):
        return out
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name), encoding="utf-8") as fh:
                j = json.load(fh)
        except (OSError, ValueError):
            continue
        pid = (j.get("project") or "").strip()
        if not pid and j.get("layout"):
            pid = j["layout"].split("/", 1)[-1]     # 形如 wtool/terminal/tmux
        if pid and is_safe_rel(pid):
            out[pid] = j
    return out


def scan_projects(root, manifests_only=False):
    """工作区里的全部项目，返回 [(priority, id, abspath, publish_info)]。

    manifests_only=True 时只返回**有 wtool.xml 的项目**。
    这是"这是不是一个 wtool 项目"的唯一判据 —— 一个仓库只有声明了 wtool.xml，
    才谈得上可安装、可构建、可发布。没有它的仓库（上游源码、别人维护的主题）
    不是 wtool 项目，要么归某个伞项目的 wtool.xml 管，要么就不该出现在界面上。

    默认 False 会额外从 repo manifest 和 .wtool-dist 标记里补全项目，
    那是给"解压出来的工作区"用的（没有 .repo，只能靠标记认人）。

    项目表来自两处，按优先级合并：
      1. 有 wtool.xml 的目录 —— 它自己声明怎么发布
      2. repo manifest 里的项目 —— 自己没有 wtool.xml 的按默认源码发布
         （harness、themes/... 这些没有 wtool.xml 的项目只能从 manifest 知道）
    另外项目可以用 <sub> 替子树里没有 wtool.xml 的项目表态——上游仓
    （neovim/neovim）不可能往里塞 wtool.xml，只能从伞项目外面声明。
    <sub> 优先于 manifest 的默认值。
    """
    root = os.path.abspath(root)
    found = []            # (prio, id, path, publish)
    declared = {}         # abspath -> 来自 <sub> 的 publish
    known = set()

    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in (".repo", ".git", "node_modules", "__pycache__")]
        if "wtool.xml" not in filenames:
            continue
        errors = []
        meta, _entries = parse_manifest(os.path.join(dirpath, "wtool.xml"),
                                        dirpath, errors)
        if meta is None:
            continue
        found.append((meta["priority"], project_id_of(dirpath, root),
                      dirpath, effective_publish(dirpath, meta["publish"])))
        known.add(os.path.abspath(dirpath))
        for sub in meta["publish"]["subs"]:
            sub_abs = os.path.normpath(os.path.join(dirpath, sub["path"]))
            declared[sub_abs] = dict(sub, _by=project_id_of(dirpath, root))
        # 这里**不能**剪枝。项目是可以嵌套的（repo manifest 里
        # editor/astronvim_v5 和 editor/astronvim_v5/astronvim_v5_config
        # 就是父子关系），剪掉就再也扫不到子项目了。
        # 有 .repo 时 manifest 能补全，但没有 .repo 的工作区
        # （比如从发布包解压出来的）就只能靠这次遍历。

    # repo manifest 补全：没有 wtool.xml 的项目
    for rel in (() if manifests_only else sorted(_repo_manifest_projects(root))):
        abs_p = os.path.normpath(os.path.join(root, rel))
        if abs_p in known or not os.path.isdir(abs_p):
            continue
        if rel in (".", ""):
            continue
        pub = {"kind": "source", "script": "", "tag": DEFAULT_PUBLISH_TAG,
               "to": "", "asset": "", "subs": [], "targets": [], "_from": "manifest"}
        found.append((DEFAULT_PRIORITY, rel, abs_p, pub))
        known.add(abs_p)

    # 发布标记补全：解压出来的工作区没有 .repo，靠 .wtool-dist/ 里的标记
    # 才知道哪些项目被发布过（harness、themes/... 这些没有 wtool.xml 的只能这样找）
    _dist_items = () if manifests_only else sorted(_dist_marker_projects(root).items())
    for pid, j in _dist_items:
        abs_p = os.path.normpath(os.path.join(root, pid))
        if abs_p in known or not os.path.isdir(abs_p):
            continue
        found.append((DEFAULT_PRIORITY, pid, abs_p,
                      {"kind": "source", "script": "", "tag": DEFAULT_PUBLISH_TAG,
                       "to": "", "asset": "", "subs": [], "targets": [],
                       "_from": "dist", "_commit": j.get("commit") or ""}))
        known.add(abs_p)

    # <sub> 覆盖 manifest 的默认值
    for sub_abs, sub in sorted(declared.items()):
        pub = {"kind": sub["kind"], "script": "", "tag": DEFAULT_PUBLISH_TAG,
               "to": sub["to"], "asset": "", "subs": [], "targets": [],
               "_sub_of": sub["_by"]}
        if os.path.abspath(sub_abs) in known:
            for i, (prio, pid, path, old) in enumerate(found):
                if os.path.abspath(path) == os.path.abspath(sub_abs) and \
                        old.get("kind") == "source" and old.get("_from") == "manifest":
                    found[i] = (prio, pid, path, pub)
            continue
        # manifests_only 时不把子仓库单独列成一行 ——
        # 它们是**伞项目管的**（astronvim_v5 管着它自己的 config 仓和上游 nvim），
        # 不是一个独立的 wtool 项目。界面上该看到的只有伞项目那一行。
        if manifests_only:
            continue
        rel = os.path.relpath(sub_abs, root)
        found.append((DEFAULT_PRIORITY, rel, sub_abs, pub))
        known.add(os.path.abspath(sub_abs))

    return sorted(found)


def list_projects(root):
    """扫描工作区里所有 wtool.xml，按 (priority, id) 排序输出。

    列数固定为 3（prio/id/path），调用方按列读，不要加列。

    只列**有 wtool.xml 的项目** —— bootstrap 和 uninstall 拿这份列表去
    逐个动作，而纯数据项目（harness、主题之类）没有清单、没有可执行的东西。
    表格和 publish 要的是"全部项目"，那走 publish-list（它基于
    scan_projects，会从 repo manifest 和发布标记里补全）。
    """
    for prio, pid, path, _pub in scan_projects(root, manifests_only=True):
        print("%d\t%s\t%s" % (prio, pid, path))


def sudo_list(root):
    """声明了系统层（<sudo-install> / <source>）的项目：prio id path。

    `wtool sudo-install`（不带参数）和 `wtool sudo-bootstrap` 拿它当工作清单。
    """
    for prio, pid, path, _pub in scan_projects(root, manifests_only=True):
        errors, warnings = [], []
        _meta, entries = parse_manifest(os.path.join(path, "wtool.xml"), path,
                                        errors, warnings)
        if any(e.kind in ("sysfile", "source", "task") for e in entries):
            print("%d\t%s\t%s" % (prio, pid, path))


def publish_list(root):
    """列出所有 wtool 项目的发布方式：prio id path kind script tag to"""
    for prio, pid, path, pub in scan_projects(root, manifests_only=True):
        print("\t".join([str(prio), pid, path, pub["kind"],
                         pub.get("script") or "-", pub.get("tag") or "",
                         pub.get("to") or "-"]))


def publish_info(project_dir, ws_root=None):
    """单个项目的发布信息，key<TAB>value 逐行输出，供 shell 读取。"""
    root = os.path.abspath(project_dir)
    errors = []
    meta = None
    if os.path.isfile(os.path.join(root, "wtool.xml")):
        meta, _entries = parse_manifest(os.path.join(root, "wtool.xml"), root, errors)
    if meta is None:
        # 没有 wtool.xml 就是默认源码发布（这不是错误）
        meta = {"priority": DEFAULT_PRIORITY,
                "publish": {"kind": "source", "script": "", "tag": DEFAULT_PUBLISH_TAG,
                            "to": "", "asset": "", "subs": [], "targets": [],
                            "_declared": False},
                "build": {"kind": "local", "min_cores": None, "min_mem_gb": None,
                          "min_disk_gb": None, "_declared": False}}
    pub = effective_publish(root, meta["publish"])
    # 身份 = 相对工作区的路径（和 plan_install / 看板 / state 目录同一个来源）
    _pid = project_id_of(root, ws_root or None)
    print("project_id\t%s" % _pid)
    print("project_root\t%s" % root)
    print("priority\t%s" % meta.get("priority", DEFAULT_PRIORITY))
    print("kind\t%s" % pub["kind"])
    print("script\t%s" % (pub.get("script") or "-"))
    print("tag\t%s" % (pub.get("tag") or DEFAULT_PUBLISH_TAG))
    print("to\t%s" % (pub.get("to") or "-"))
    print("asset\t%s" % (pub.get("asset") or "-"))
    # 构建方式（ADR-025）：kind 决定 __output/ 的形状，min-* 决定这台机器够不够
    _bld = meta.get("build") or {}
    print("build\t%s" % (_bld.get("kind") or "local"))
    print("min_cores\t%s" % (_bld.get("min_cores") if _bld.get("min_cores") else "-"))
    print("min_mem_gb\t%s" % (_bld.get("min_mem_gb") if _bld.get("min_mem_gb") else "-"))
    print("min_disk_gb\t%s" % (_bld.get("min_disk_gb") if _bld.get("min_disk_gb") else "-"))
    for sub in pub.get("subs", []):
        print("sub\t%s\t%s\t%s" % (sub["path"], sub["kind"], sub["to"] or "-"))
    for tgt in pub.get("targets", []):
        print("target\t%s\t%s\t%s\t%s" % (tgt["os"], tgt["version"],
                                          tgt["codename"] or "-", tgt["image"] or "-"))
    for e in errors:
        print("error\t%s" % e, file=sys.stderr)
    return 1 if errors else 0


# --------------------------------------------------------------------------
# 声明认领：一条 $HOME 软链还有没有别的项目要它
#
# uninstall 拆软链之前必须先问这一句（见 harness/architecture.md §4.2）：
# 判据是**磁盘上所有 wtool 项目的 wtool.xml**，不是 registry ——
# registry 只能有一个主人，而"两个项目都要 ~/.gitconfig"是完全合理的。
# --------------------------------------------------------------------------
def claimed_homes(root, exclude_id="", home=""):
    """[(abs_dest, project_id), ...]：别的项目声明的 $HOME 落点。"""
    home = os.path.abspath(home) if home else ""
    out = []
    for _prio, pid, path, _pub in scan_projects(root, manifests_only=True):
        if pid == exclude_id:
            continue
        errors, warnings = [], []
        _meta, entries = parse_manifest(os.path.join(path, "wtool.xml"), path,
                                        errors, warnings)
        for entry in entries:
            if entry.kind != "link":
                continue
            out.append((os.path.join(home, entry.home), pid))
    return sorted(set(out))


# --------------------------------------------------------------------------
# pack-release：把项目打成 __release/ 里的分卷
#
# Python 只算"打哪些文件"（读 .gitignore 是文本逻辑），实际打包、切卷、
# 算 sha256 由 shell 侧做（wtool_fs.sh），产物落在 <项目>/__release/。
# --------------------------------------------------------------------------
# 三个"跑起来才有"的目录，名字带 `__` 前缀（用户 2026-10-04 要求，见 ADR-0033）：
# 一眼看出它们不是仓库自带的目录，`ls` 时也和源码分得开。
# 旧的 output/ release/ layer/ 也列在忽略表里 —— 老工作区里可能还留着，
# 别让它们被打进源码包（那是 GB 级的）。
DIR_OUT = "__output"
DIR_REL = "__release"
DIR_LAYER = "__layer"

ALWAYS_IGNORED_DIRS = (DIR_OUT, DIR_REL, DIR_LAYER,      # 新名字
                       "output", "release", "layer",      # 旧名字：老工作区里还在，GB 级
                       ".git", "__pycache__",
                       ".mypy_cache", ".pytest_cache", ".ruff_cache")


def _git_ls_files(root):
    """在 git 工作区里时，让 git 自己算文件表 —— 它就是 .gitignore 的权威实现。

    返回 None 表示"不是 git 工作区/git 不可用"，调用方改用自带的解析器。
    """
    try:
        p = subprocess.run(["git", "-C", root, "rev-parse", "--is-inside-work-tree"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if p.returncode != 0 or p.stdout.strip() != b"true":
        return None
    try:
        p = subprocess.run(["git", "-C", root, "ls-files", "-z", "-co",
                            "--exclude-standard"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return None
    if p.returncode != 0:
        return None
    return [f.decode("utf-8", "surrogateescape")
            for f in p.stdout.split(b"\0") if f]


def _ignore_regex(pattern):
    """把 .gitignore 的一行编译成正则。够用就好：发布副本里没有 .git，
    这条路只在"没有 git 可用"时兜底。"""
    pat = pattern.rstrip()
    anchored = pat.startswith("/")
    pat = pat.lstrip("/")
    out, i = [], 0
    while i < len(pat):
        c = pat[i]
        if c == "*":
            if pat[i:i + 2] == "**":
                out.append(".*")
                i += 2
                if pat[i:i + 1] == "/":
                    i += 1
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c == "[":
            j = pat.find("]", i)
            if j < 0:
                out.append(re.escape(c))
            else:
                out.append(pat[i:j + 1])
                i = j
        else:
            out.append(re.escape(c))
        i += 1
    body = "".join(out)
    if anchored or "/" in pat:
        return re.compile(r"^" + body + r"(/.*)?$")
    return re.compile(r"(^|.*/)" + body + r"(/.*)?$")


def _gitignore_rules(root):
    """收集项目里所有 .gitignore 的规则：(base_rel, regex, negate)。"""
    rules = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ALWAYS_IGNORED_DIRS]
        if ".gitignore" not in filenames:
            continue
        base = os.path.relpath(dirpath, root)
        if base == ".":
            base = ""
        for line in (read_text(os.path.join(dirpath, ".gitignore")) or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            negate = line.startswith("!")
            if negate:
                line = line[1:]
            if not line:
                continue
            rules.append((base, _ignore_regex(line), negate))
    return rules


def _ignored(rel, is_dir, rules):
    hit = False
    for base, rx, negate in rules:
        if base:
            if rel == base:
                sub = ""
            elif rel.startswith(base + "/"):
                sub = rel[len(base) + 1:]
            else:
                continue
        else:
            sub = rel
        if rx.match(sub):
            hit = not negate
    return hit


def source_file_list(project_root):
    """源码包里要打进去的文件（相对项目目录，已按路径排序）。

    **一定读 .gitignore**：不读的话 GB 级的 __output/ 会被原样打进源码包
    （实测过）。git 可用就让 git 算，否则自己解析 .gitignore。
    另外无论 .gitignore 怎么写，__output/、__release/、__layer/ 永远排除。
    """
    root = os.path.abspath(project_root)
    files = _git_ls_files(root)
    if files is None:
        files = []
        rules = _gitignore_rules(root)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in ALWAYS_IGNORED_DIRS]
            for name in filenames:
                files.append(os.path.relpath(os.path.join(dirpath, name), root))

    picked = []
    for rel in files:
        rel = rel.replace(os.sep, "/")
        if not is_safe_rel(rel):
            continue
        head = rel.split("/")[0]
        if head in ALWAYS_IGNORED_DIRS:
            continue
        if not os.path.lexists(os.path.join(root, rel)):
            continue                      # git 索引里有、磁盘上没有的文件
        if os.path.isdir(os.path.join(root, rel)) \
                and not os.path.islink(os.path.join(root, rel)):
            continue                      # 子模块之类的 gitlink
        picked.append(rel)
    return sorted(set(picked))


def release_file_list(project_root):
    """__output/ 里的文件（相对项目目录）。文件从这儿来，装到别的机器上去。"""
    root = os.path.abspath(project_root)
    rel_root = os.path.join(root, DIR_OUT)
    out = []
    if not os.path.isdir(rel_root):
        return out
    for dirpath, _dirnames, filenames in os.walk(rel_root):
        for name in filenames:
            p = os.path.join(dirpath, name)
            out.append(os.path.relpath(p, root).replace(os.sep, "/"))
    return sorted(out)


def pack_plan(args):
    """写三张清单到 scratch：源码包的文件、release 包的文件、声明面。"""
    root = os.path.abspath(args.project)
    scratch = args.scratch
    os.makedirs(scratch, exist_ok=True)
    src_files = source_file_list(root)
    rel_files = release_file_list(root)
    declare = [f for f in DECLARE_FILES if os.path.isfile(os.path.join(root, f))]

    with open(os.path.join(scratch, "source.files"), "w",
              encoding="utf-8", errors="surrogateescape") as fh:
        fh.write("\n".join(src_files) + ("\n" if src_files else ""))
    with open(os.path.join(scratch, "release.files"), "w",
              encoding="utf-8", errors="surrogateescape") as fh:
        fh.write("\n".join(rel_files) + ("\n" if rel_files else ""))
    with open(os.path.join(scratch, "declare.tsv"), "w", encoding="utf-8") as fh:
        for name in declare:
            fh.write("%s\t%s\n" % (name, name))
    return {"root": root, "source": src_files, "release": rel_files,
            "declare": declare}


def write_dist(args):
    """把 shell 算好的分卷表落成 dist.json（写 scratch，由 shell 拷走）。"""
    rows = _read_tsv(args.rows)
    files, volumes = [], []
    for row in rows:
        if len(row) < 4:
            continue
        name, sha, size, role = row[0], row[1], row[2], row[3]
        of = row[4] if len(row) > 4 else ""
        try:
            nbytes = int(size or 0)
        except ValueError:
            nbytes = 0
        if of:
            volumes.append({"name": name, "sha256": sha, "bytes": nbytes, "of": of})
        else:
            files.append({"name": name, "role": role, "sha256": sha, "bytes": nbytes})

    dist = {
        "schema": 1,
        "project": args.project_id,
        "tag": args.tag,
        "repo": args.repo,
        "base_url": "https://github.com/%s/releases/download/%s" % (args.repo, args.tag),
        "packed_at": args.at or "",
        "commit": args.commit or "",
        "volume_size": args.volume_size,
        "declare": [d for d in (args.declare or "").split(",") if d],
        # 顺序有意义：volumes 按顺序逐个拼接就是原来的大文件
        "files": files,
        "volumes": volumes,
        "how": ("把 dist.json 和所有分卷下到项目的 __release/ 目录，然后："
                "wtool unpack-release <项目> ；wtool install <项目>"),
    }
    text = json.dumps(dist, ensure_ascii=False, indent=2) + "\n"
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(text)
    return dist


def _downloadable_rows(rows):
    """从 rows.tsv 里挑出**真正能下载的东西**。

    rows.tsv 的每一行是 `名字 sha256 字节 role of`：
    被切成卷的大文件（of 非空的行指向它）本身不留在 __release/ 里，
    所以下载页和 downloads.sh 都不该列它 —— 列了就是 404。
    """
    split = {row[4] for row in rows if len(row) > 4 and row[4]}
    out = []
    for row in rows:
        if len(row) < 2:
            continue
        if len(row) > 4 and row[4]:
            out.append(row)                      # 分卷：要下
        elif row[0] in split:
            continue                             # 被切开的原始大文件：不在 __release/ 里
        else:
            out.append(row)
    return out


# --------------------------------------------------------------------------
# 容器构建（kind="docker"）的清单：build/targets.tsv + build/layers.tsv
#
# ADR-0025 说"引擎管生命周期，项目管每一层装什么"；ADR-0029 把这句话落成两个约定文件 ——
# 只有 **kind** 进 wtool.xml，清单住项目目录（形状固定，不用在 XML 里再声明路径）。
#
# 这里的三个函数**只算不写**：解析、校验、排序、把 {target} 替换掉，
# 真正起容器 / commit / 导出的是 wtool.sh（wt_docker_build）。
# --------------------------------------------------------------------------

DOCKER_BUILD_DIR = "build"
DOCKER_TARGETS_FILE = "targets.tsv"
DOCKER_LAYERS_FILE = "layers.tsv"
DOCKER_EXPORT_FILTER = "export.filter"


def _tsv_rows(path):
    """读一张两列以上的 TSV：跳空行和 `#` 注释，返回 [[字段...], ...]。"""
    rows = []
    try:
        with open(path, encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, 1):
                line = raw.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                rows.append([f.strip() for f in line.split("\t")])
    except OSError:
        return None
    return rows


def docker_manifest_paths(project_dir):
    base = os.path.join(os.path.abspath(project_dir), DOCKER_BUILD_DIR)
    return (os.path.join(base, DOCKER_TARGETS_FILE),
            os.path.join(base, DOCKER_LAYERS_FILE),
            os.path.join(base, DOCKER_EXPORT_FILTER))


def docker_targets(project_dir):
    """`build/targets.tsv` → [(target, image), ...]；文件不在/坏了就抛 ValueError。"""
    tpath, _lpath, _fpath = docker_manifest_paths(project_dir)
    rows = _tsv_rows(tpath)
    if rows is None:
        raise ValueError("没有 %s —— kind=\"docker\" 的项目要有它和 %s（ADR-0029）"
                         % (os.path.relpath(tpath, project_dir),
                            DOCKER_LAYERS_FILE))
    out = []
    for i, row in enumerate(rows, 1):
        if len(row) < 2 or not row[0] or not row[1]:
            raise ValueError("%s 第 %d 行要至少两列：<target>\\t<docker 镜像>"
                             % (DOCKER_TARGETS_FILE, i))
        out.append((row[0], row[1]))
    if not out:
        raise ValueError("%s 里一个目标都没有" % DOCKER_TARGETS_FILE)
    return out


def docker_layers(project_dir):
    """`build/layers.tsv` → [(层名, 父层, 镜像名, 命令), ...]，按**文件顺序**。

    四列：`层名 \t 父层 \t 镜像名 \t 容器里跑的命令`
      · 父层 `-`      = 从目标系统的基础镜像出发（第一层）
      · 镜像名 `-`    = 占位层：不构建，只留一个空的 __output 层
      · 命令里的 `{target}` 会被替换成当前目标（引擎替换，这里只校验）
    """
    _tpath, lpath, _fpath = docker_manifest_paths(project_dir)
    rows = _tsv_rows(lpath)
    if rows is None:
        raise ValueError("没有 %s（kind=\"docker\" 的层清单，见 ADR-0029）"
                         % os.path.relpath(lpath, project_dir))
    out = []
    seen = set()
    for i, row in enumerate(rows, 1):
        if len(row) < 4 or not row[0]:
            raise ValueError("%s 第 %d 行要四列：<层名>\\t<父层>\\t<镜像名>\\t<命令>"
                             % (DOCKER_LAYERS_FILE, i))
        layer, parent, image, cmd = row[0], row[1], row[2], row[3]
        if layer in seen:
            raise ValueError("%s 第 %d 行：层名 %r 重复" % (DOCKER_LAYERS_FILE, i, layer))
        seen.add(layer)
        if parent not in ("-", "") and parent not in [r[0] for r in out] +                 [r[0] for r in rows]:
            raise ValueError("%s 第 %d 行：父层 %r 不在清单里"
                             % (DOCKER_LAYERS_FILE, i, parent))
        if image == "-" and cmd != "-":
            raise ValueError("%s 第 %d 行：镜像名是 `-`（占位层）时命令也得是 `-`"
                             % (DOCKER_LAYERS_FILE, i))
        if parent not in ("-", "") and image != "-":
            _pimg = dict((r[0], r[2]) for r in out).get(parent)
            if _pimg == "-":
                raise ValueError("%s 第 %d 行：层 %r 的父层 %r 是个占位层（没有镜像），"
                                 "子层没有出发点" % (DOCKER_LAYERS_FILE, i, layer, parent))
        if image != "-" and cmd == "-":
            raise ValueError("%s 第 %d 行：层 %r 有镜像名却没有命令 —— 这一层装什么？"
                             % (DOCKER_LAYERS_FILE, i, layer))
        out.append((layer, parent if parent else "-", image, cmd))
    if not out:
        raise ValueError("%s 里一层都没有" % DOCKER_LAYERS_FILE)
    return out


def docker_plan_order(layers):
    """按依赖排执行顺序：父层必须在子层前面。

    **稳定**：同一批"父层已就绪"的层按清单里的先后走（不用字典序，
    免得"某个语言先编"这种顺序变化让人以为行为变了）。
    有环 → ValueError（清单写错了，不能猜）。
    """
    done, order = set(), []
    pending = list(layers)
    while pending:
        progressed = False
        for item in list(pending):
            _layer, parent, _image, _cmd = item
            if parent == "-" or parent in done:
                order.append(item)
                done.add(_layer)
                pending.remove(item)
                progressed = True
        if not progressed:
            raise ValueError("层清单里有环（或者父层不存在）：%s"
                             % ", ".join(i[0] for i in pending))
    return order


def release_targets(project_dir):
    """`release.json` 的 `targets[]` —— **形状由声明决定，引擎不嗅探**（ADR-025）。

    | `<build kind>` | `__output/` 的形状 | targets[] |
    |---|---|---|
    | `docker` | `__output/<os>_<ver>/<层>/…` | 每个 `<os>_<ver>` 一个名字 |
    | `local`  | `__output/<层>/…`（没有 target 那一层） | **空** |

    `kind="local"` 时如果照旧扫 `__output/*/`，扫出来的是**层名**（"bin"、"main"）
    —— 那是假信息：对静态链接的产物来说，"这一版是给哪个发行版的"根本不存在。
    """
    root = os.path.abspath(project_dir)
    errors = []
    meta = None
    if os.path.isfile(os.path.join(root, "wtool.xml")):
        meta, _entries = parse_manifest(os.path.join(root, "wtool.xml"), root, errors)
    kind = ((meta or {}).get("build") or {}).get("kind") or "local"
    if kind != "docker":
        return ""
    out = os.path.join(root, DIR_OUT)
    try:
        names = sorted(d for d in os.listdir(out)
                       if os.path.isdir(os.path.join(out, d)))
    except OSError:
        return ""
    return ",".join(names)


def release_json(args):
    """`scripts/release.json` 的内容：**提交进仓库**的发布声明（ADR-026）。

    它是 `wtool download-release` **唯一要读的东西**，所以必须自足：
    光凭它就能拼出每个资产的下载地址、校验 sha256 —— 不用先下任何东西
    （这一点是它和 `__release/dist.json` 的根本区别：后者跟着包走，
    和包同源，所以只能用来拼卷，不能当"可信清单"）。

    资产表**按 `__release/` 目录里实际有的文件**算（和 `publish-release`
    上传时用的 `find -maxdepth 1 -type f` 同一条规则）—— 保证"清单里有的
    就是传上去的"，不会漂移。role 从 dist.json 里补，补不到的留空。

    Python 只算不写：这里 print 出来，落盘由 shell 侧的 `wt_atomic_write` 干。
    """
    rel_dir = os.path.abspath(args.release_dir)
    dist_path = os.path.abspath(args.dist) if args.dist else \
        os.path.join(rel_dir, "dist.json")

    dist = {}
    if os.path.isfile(dist_path):
        try:
            with open(dist_path, encoding="utf-8") as fh:
                dist = json.load(fh)
        except (OSError, ValueError) as exc:
            sys.stderr.write("读不了 %s: %s\n" % (dist_path, exc))
            raise SystemExit(1)

    roles = {}
    for f in dist.get("files", []):
        roles[f.get("name", "")] = f.get("role", "")
    for v in dist.get("volumes", []):
        roles[v.get("name", "")] = "volume"

    assets = []
    if os.path.isdir(rel_dir):
        for name in sorted(os.listdir(rel_dir)):
            # `.source` 是引擎自己的来源标记，不是发布资产
            if name.startswith("."):
                continue
            fp = os.path.join(rel_dir, name)
            if not os.path.isfile(fp):
                continue
            with open(fp, "rb") as fh:
                sha = hashlib.sha256()
                while True:
                    chunk = fh.read(1 << 20)
                    if not chunk:
                        break
                    sha.update(chunk)
            assets.append({"name": name,
                           "role": roles.get(name, ""),
                           "bytes": os.path.getsize(fp),
                           "sha256": sha.hexdigest()})

    pid = dist.get("project") or args.project_id or ""
    targets = [t for t in (args.targets or "").split(",") if t]
    out = {
        "schema": 1,
        "project": pid,
        "repo": dist.get("repo", ""),
        "tag": dist.get("tag", ""),
        "base_url": dist.get("base_url", ""),
        "commit": dist.get("commit", ""),
        "packed_at": dist.get("packed_at", ""),
        "published_at": args.at or "",
        "wtool_engine": args.engine or "",
        "dirty": args.dirty == "1",
        "volume_size": dist.get("volume_size", ""),
        "declare": dist.get("declare", []),
        # ⚠️ 今天只有 target 名字；glibc / arch 要等项目侧的 targets 清单
        # 定下来（BL-28）才补得上。补上之前 download-release 不能按 glibc 选包。
        "targets": [{"target": t} for t in targets],
        "assets": assets,
        "how": ("wtool download-release %s   # 下到项目的 __release/（按本文件的 sha256 校验）\n"
                "wtool unpack-release %s     # 拼分卷 + 解到 __output/\n"
                "wtool install %s            # 装到本机" % (pid, pid, pid)),
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def download_doc(args):
    """`docs/download.md` 的内容：给人看的下载页。

    ⚠️ **资产表必须和 `scripts/release.json` 的 `assets[]` 是同一批文件** ——
    两者都按 `__release/` 目录里**实际有什么**算（不是按"源码包/产物包"那一类算）。
    漏掉 `dist.json` 或 `*-hash.txt` 的话，照页面手动下的人会缺文件，
    而 `unpack-release` 正好要 `dist.json` 才拼得了分卷。

    人分两类，页面要同时照顾：
      · 装了 wtool 的 —— 三条命令搞定，走 `download-release` + `unpack-release`；
      · 只有浏览器的 —— 手点上面那些直链，下完放进项目的 `__release/` 再 unpack。
    """
    base = "https://github.com/%s/releases/download/%s" % (args.repo, args.tag)
    roles = {}
    for row in _read_tsv(args.rows):
        if len(row) < 4:
            continue
        roles[row[0]] = "volume" if (len(row) > 4 and row[4]) else row[3]

    assets = []
    rel_dir = getattr(args, "release_dir", "") or ""
    if rel_dir and os.path.isdir(rel_dir):
        for name in sorted(os.listdir(rel_dir)):
            if name.startswith("."):            # `.source` 是引擎自己的标记
                continue
            fp = os.path.join(rel_dir, name)
            if os.path.isfile(fp):
                assets.append((name, os.path.getsize(fp), roles.get(name, "")))
    else:
        # 兜底：没给目录（老调用方式）就退回按 rows 渲染
        for row in _downloadable_rows(_read_tsv(args.rows)):
            try:
                size = int(row[2] or 0)
            except ValueError:
                size = 0
            assets.append((row[0], size, row[3] if len(row) > 3 else ""))

    _role_cn = {"source": "源码包", "release": "产物包", "volume": "分卷"}
    out = ["# 下载 %s" % args.project_id,
           "",
           "这一版：`%s`%s" % (args.tag, ("（%s）" % args.at if args.at else "")),
           "",
           "| 文件 | 大小 | 是什么 | 直链 |",
           "|---|---|---|---|"]
    for name, size, role in assets:
        out.append("| `%s` | %s | %s | %s/%s |"
                   % (name, _human_size(size), _role_cn.get(role, role or "—"),
                      base, name))
    out += ["",
            "## 怎么装",
            "",
            "**装了 wtool 的机器**（推荐，校验和拼分卷它自己做）：",
            "",
            "```sh",
            "wtool download-release %s   # 按仓库里提交的 scripts/release.json 下载 + 校验" % args.project_id,
            "wtool unpack-release %s     # 拼分卷 + 解到 __output/" % args.project_id,
            "wtool install %s            # 装到本机（登记、软链、shell 集成）" % args.project_id,
            "```",
            "",
            "**只有浏览器的机器**：把上面每个文件点下来，放进项目的 `__release/` 目录，",
            "再在那台机器上跑后两条命令 —— `unpack-release` 认包里的 `dist.json`，",
            "缺了哪一卷它会说清楚。",
            "",
            "`install` 只认 `release.zip`（产物包），不需要 `源码.zip`。",
            ""]
    print("\n".join(out), end="")


def _human_size(n):
    units = ("B", "K", "M", "G", "T")
    v = float(n)
    for u in units:
        if v < 1024 or u == units[-1]:
            return "%d%s" % (v, u) if u == "B" else "%.1f%s" % (v, u)
        v /= 1024.0
    return "%d" % n


# --------------------------------------------------------------------------
# check：声明 / 日志 / 磁盘 三者对比，只报不改
# --------------------------------------------------------------------------
def _journal_rows(state, pid):
    return _read_tsv(os.path.join(state, pid, "journal.tsv"))


def do_check(args):
    home = os.path.abspath(args.home)
    state = os.path.abspath(args.state)
    root = os.path.abspath(args.root)
    problems = []

    def bad(pid, msg):
        problems.append((pid, msg))

    projects = scan_projects(root, manifests_only=True)
    want_id = ""
    if args.project:
        # 相对路径按**工作区根**解析，不按当前目录 —— 项目身份就是相对工作区根的
        # 路径，两条口径必须一致。
        want = args.project
        want_abs = os.path.abspath(want if os.path.isabs(want)
                                   else os.path.join(root, want))
        projects = [p for p in projects if os.path.abspath(p[2]) == want_abs]
        if not projects:
            # 磁盘上没有这个项目：可能是"改掉的旧路径"（ADR-0037 的残渣），
            # 也可能只是拼错了。留给下面残渣那一节去认，认不出就一条也不报。
            want_id = project_id_of(want_abs, root)

    # ---- 全局：~/usr 这条引擎自己造的软链
    usr_dest = os.path.join(home, "usr")
    usr_target = os.path.join(home, SHADOW_ROOT_NAME, "usr")
    if os.path.islink(usr_dest):
        if os.path.normpath(os.readlink(usr_dest)) != os.path.normpath(usr_target):
            bad("-", "~/usr 指向了别处: %s（应该是 %s）"
                % (os.readlink(usr_dest), usr_target))
    elif os.path.exists(usr_dest):
        bad("-", "~/usr 存在但不是软链（应该是 → ~/.wtool/usr）")
    elif _installed_ids(state):
        bad("-", "~/usr 不见了（有项目装着，它应该在）")

    # ---- 全局：env 汇总与 loader 块
    # 汇总文件两个 shell 都要查：只查 zsh 的话，`~/.wtool/.bashrc` 被误删时
    # check 一声不吭，而"那个 shell 的用户敲命令 command not found"——
    # 正是最难查的半装状态（BL-24；生成那一侧本来就两个 shell 都做了）。
    for shell in ("zsh", "bash"):
        agg = os.path.join(home, SHADOW_ROOT_NAME, ".%src" % shell)
        blocks = collect_env_blocks(state, shell)
        if blocks and not os.path.isfile(agg):
            bad("-", "~/.wtool/.%src 不见了，但还有 %d 个项目的 env 块" % (shell, len(blocks)))
        rc = os.path.join(home, ".%src" % shell)
        text = read_text(rc) or ""
        has_loader = any(l.strip() == LOADER_BEGIN for l in text.split("\n"))
        has_blocks = bool(collect_env_blocks(state, shell))
        if has_blocks and not has_loader:
            bad("-", "%s 里没有 wtool 的 loader 块（env 不会生效）" % rc)
        if has_loader and not has_blocks:
            bad("-", "%s 里有 loader 块，但一个项目的 env 块都没有" % rc)

    # ---- 逐项目
    for _prio, pid, path, pub in projects:
        errors, warnings = [], []
        meta, entries = parse_manifest(os.path.join(path, "wtool.xml"), path,
                                       errors, warnings)
        for e in errors:
            bad(pid, "清单有问题: %s" % e)
        if meta is None:
            continue
        verrors, vwarnings = [], []
        validate_entries(entries, path, home, state, verrors, vwarnings)
        for e in verrors:
            bad(pid, "声明与磁盘对不上: %s" % e)

        journal = _journal_rows(state, pid)
        if not journal and not os.path.isfile(os.path.join(state, pid, "meta.tsv")):
            # 没装过**不是**"坏了"：扫全部项目时（wtool check）静默跳过，
            # 只有明确点了这个项目才提一句（那时候人是想知道它为什么没生效）。
            if args.project and any(e.kind in ("link", "env") for e in entries):
                bad(pid, "还没装过（wtool install <路径>）")
            continue

        owned = set()
        for row in journal:
            act = row[0] if row else ""
            dest = row[2] if len(row) > 2 else ""
            target = row[3] if len(row) > 3 else "-"
            owned.add(dest)
            if act == "link":
                if not os.path.islink(dest):
                    if os.path.exists(dest):
                        bad(pid, "%s 已经不是软链了（被换成了实体）" % dest)
                    else:
                        bad(pid, "%s 不见了（wtool repair 可以补）" % dest)
                elif target != "-" and os.path.normpath(os.readlink(dest)) \
                        != os.path.normpath(target):
                    bad(pid, "%s 指向变了: %s（记录的是 %s）"
                        % (dest, os.readlink(dest), target))
            elif act == "sysfile":
                if os.path.exists(dest) and os.path.exists(os.path.join(
                        state, pid, "system")):
                    pass

        # 声明里有、日志里没有 → 装的时候没带上（或者被人手工删过）
        for entry in entries:
            if entry.kind != "link" or getattr(entry, "skip", False):
                continue
            for dest, _want in _link_hops(entry, links_dir_for(home, pid)):
                if dest not in owned and (os.path.lexists(dest) or
                                          dest == entry.abs_dest):
                    if dest == entry.abs_dest and not os.path.lexists(dest):
                        bad(pid, "%s 没建（wtool repair 可以补）" % dest)

        # env 块：声明了 zshrc/bashrc，state 里得有对应的块文件
        for entry in entries:
            if entry.kind != "env" or getattr(entry, "skip", False):
                continue
            for shell in entry.shells:
                if shell not in RC_CAPABLE_SHELLS:
                    continue
                blk = os.path.join(state, pid, "env.%s" % shell)
                if not os.path.isfile(blk):
                    bad(pid, "%s 的 env 块不见了: %s" % (shell, blk))

    # ---- 改名 / 删目录留下的残渣（ADR-0037）---------------------------------
    #
    # 项目身份 = 路径，所以**改目录 = 换了一个项目**。旧路径那一套账
    # （state 目录 / 中转软链 / env 块 / registry 行）不会自己消失 ——
    # 它们全是按旧路径建的。这一节把"state 里还有账、但**磁盘上已经没有
    # 这个项目**"的东西逐条报出来。
    #
    # 为什么值得专门查：这些残渣**大多不报错，只是静默失效** ——
    #   * env 块还在  → 它照样被拼进 ~/.wtool/.zshrc，但块里的
    #     `[ -r "$WTOOL_PROJECT_DIR/env.zsh" ]` 因为软链悬空而**静默**不生效
    #   * registry 里还挂着旧路径的行 → 下一次 `install <新路径>` 直接报
    #     "dest 已被项目 <旧路径> 占用"，要 --force 才过，过完还留一堆
    #   * links/<旧路径> 变成悬空链 → 就躺在那儿，谁也不会去点它
    #
    # 自愈的路子：`wtool uninstall <旧路径> --no-script`（账还找得到就能撤），
    # 或者一开始就用 `wtool move <旧路径> <新路径>` 改名。
    on_disk = {}
    for _prio, _pid, _path, _pub in scan_projects(root, manifests_only=True):
        on_disk[_pid] = _path
    if os.path.isdir(state):
        seen_env = set()
        for dirpath, _dirnames, filenames in os.walk(state):
            pid = os.path.relpath(dirpath, state)
            if pid == ".":
                continue
            # 哪些文件算"state 里有账"：`publish.tsv` 也算 —— 一个只发布过、
            # 从没 install 过的项目，改名之后留下的就**只有**这个文件，
            # 而它会静默把发布历史丢掉（看板那一格从「已完成」退回「未发布」）。
            # 实测：`tools/repo` → `tools/git-repo-sh-tools` 就是这种（2026-10-04）。
            if not any(n in filenames for n in ("meta.tsv", "journal.tsv",
                                                "env.zsh", "env.bash",
                                                "publish.tsv", "apt.tsv",
                                                "artifacts.tsv", "system.tsv")):
                continue
            if pid in on_disk or (want_id and pid != want_id):
                continue
            # ① 删不掉的旧 env 块（会继续进汇总文件）
            for shell in RC_CAPABLE_SHELLS:
                if "env.%s" % shell in filenames:
                    bad(pid, "state 里还留着 %s 的 env 块，但磁盘上没有这个项目了 —— "
                             "它照样被拼进 ~/.wtool/.%src，块里却 source 不到东西"
                             "（静默失效）。撤掉：wtool uninstall %s --no-script"
                        % (shell, shell, pid))
                    seen_env.add(pid)
                    break
            # ①b 没有 env 块、但有别的账 —— 典型是"只发布过、从没 install 过"的项目：
            #     不留这句话它就**完全隐形**（实测 `tools/repo` → `tools/git-repo-sh-tools`）。
            if pid not in seen_env:
                _left = [n for n in ("meta.tsv", "journal.tsv", "publish.tsv",
                                     "apt.tsv", "artifacts.tsv", "system.tsv")
                         if n in filenames]
                if _left:
                    bad(pid, "state 里还留着 %s，但磁盘上没有这个项目了 —— "
                             "这是旧路径上的账（发布历史 / 安装记录），不会自己消失。"
                             "撤掉：wtool uninstall %s --no-script"
                        % ("、".join(_left), pid))
            # ② 悬空的中转软链 / $HOME 软链（journal 记着当初建了什么）
            for row in _read_tsv(os.path.join(dirpath, "journal.tsv")):
                if len(row) < 4 or row[0] != "link":
                    continue
                dest = row[2]
                if os.path.islink(dest) and not os.path.exists(dest):
                    bad(pid, "%s 是悬空软链（当初指向 %s，现在目标没了）"
                        % (dest, row[3]))
            # ③ registry 里还挂着旧路径的行 —— 下一次 install 会因此报冲突
            for row in _read_tsv(os.path.join(state, "registry.tsv")):
                if len(row) >= 2 and row[1] == pid:
                    bad(pid, "registry 里还登记着 %s（下一次 install <新路径> 会报"
                             "\"dest 已被项目 %s 占用\"）" % (row[0], pid))
                    break

    # 点了名却什么也没找到：别让"一切对得上"变成假安慰 —— 路径写错了也是
    # 一种"对不上"。只有全局扫（没给项目）时沉默才是对的。
    if want_id and not any(p == want_id for p, _m in problems):
        bad(want_id, "没有这个项目的账：项目表里没有它，state 里也没有它的记录 —— "
                     "路径写错了？（要么它压根没装过，要么已经被卸干净了）")

    for pid, msg in problems:
        print("%s\t%s" % (pid, msg))
    return 1 if problems else 0


# --------------------------------------------------------------------------
# kill-self-forever：列出要删的、要说清不删的
# --------------------------------------------------------------------------
def kill_plan(args):
    """打印要删的东西：link|<落点>|<指向>；dir|<路径>；rc|<文件>。

    只**列**，删由 shell 做（Python 只算不写）。
    """
    home = os.path.abspath(args.home)
    state = os.path.abspath(args.state)
    seen = set()
    for row in _read_tsv(os.path.join(state, "registry.tsv")):
        if len(row) < 1 or not row[0]:
            continue
        dest = row[0]
        if dest in seen:
            continue
        seen.add(dest)
        target = os.readlink(dest) if os.path.islink(dest) else "-"
        print("link\t%s\t%s" % (dest, target))
    # 每个项目 journal 里的软链（registry 可能被删过）
    if os.path.isdir(state):
        for dirpath, _dirnames, filenames in os.walk(state):
            if "journal.tsv" not in filenames:
                continue
            for row in _read_tsv(os.path.join(dirpath, "journal.tsv")):
                if len(row) < 4 or row[0] != "link":
                    continue
                if row[2] in seen:
                    continue
                seen.add(row[2])
                print("link\t%s\t%s" % (row[2], row[3]))
    usr_dest = os.path.join(home, "usr")
    usr_target = os.path.join(home, SHADOW_ROOT_NAME, "usr")
    if os.path.islink(usr_dest) and usr_dest not in seen:
        print("link\t%s\t%s" % (usr_dest, usr_target))
    for shell in ("zsh", "bash"):
        print("rc\t%s" % os.path.join(home, ".%src" % shell))
    print("dir\t%s" % os.path.join(home, SHADOW_ROOT_NAME))
    print("dir\t%s" % state)
    return 0


def read_dist(args):
    """把 dist.json 摊平成 shell 好读的行。

    file   <名字> <sha256> <字节> <role>
    volume <名字> <sha256> <字节> <拼给谁>
    meta   <键> <值>
    """
    try:
        with open(args.dist, encoding="utf-8") as fh:
            dist = json.load(fh)
    except (OSError, ValueError) as exc:
        print("wtool: error: 读不了 dist.json: %s" % exc, file=sys.stderr)
        return 2
    for f in dist.get("files", []):
        print("file\t%s\t%s\t%s\t%s" % (f.get("name", ""), f.get("sha256", "-"),
                                        f.get("bytes", 0), f.get("role", "")))
    for v in dist.get("volumes", []):
        print("volume\t%s\t%s\t%s\t%s" % (v.get("name", ""), v.get("sha256", "-"),
                                          v.get("bytes", 0),
                                          v.get("of", "")))
    for key in ("project", "tag", "repo", "base_url", "compression", "volume_size"):
        if dist.get(key):
            print("meta\t%s\t%s" % (key, dist[key]))
    if not dist.get("files") and dist.get("volumes"):
        # 老格式（astronvim 的 publish.sh 自己写的）：只有 volumes + compression，
        # 拼接 + 解压之后是一棵 tar。这条是过渡路径。
        print("meta\tlegacy\t1")
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="wtool_plan.py", add_help=True)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, need_project=True):
        if need_project:
            sp.add_argument("project", nargs="?")
        sp.add_argument("--home", required=True)
        sp.add_argument("--state", required=True)
        sp.add_argument("--scratch", required=True)
        # 工作区根。项目身份 = 项目相对它的路径，所以这个值必须是**显式**的，
        # 不能靠猜（WTOOL_ROOT 是兜底，没传时才用）。
        sp.add_argument("--root", default="")
        sp.add_argument("--head", default="")
        sp.add_argument("--at", default="")
        sp.add_argument("--force", action="store_true")

    ip = sub.add_parser("plan-install")
    common(ip)
    # BL-15：清掉"清单里已经删掉、磁盘上还在"的软链（默认关，opt-in）
    ip.add_argument("--prune", action="store_true")
    up = sub.add_parser("plan-uninstall")
    common(up)
    # `--id` 那条路：项目根由引擎解析（扫工作区项目表）后传进来（BL-47）
    up.add_argument("--project-root", default="")
    pp = sub.add_parser("plan-provision")
    common(pp)
    pp.add_argument("--os-id", default="")
    pp.add_argument("--os-version", default="")
    pp.add_argument("--os-codename", default="")
    pp.add_argument("--arch", default="")
    pp.add_argument("--jobs", default="")
    pp.add_argument("--prefix", default="")
    pp.add_argument("--src-root", default="")

    vp = sub.add_parser("validate")
    vp.add_argument("project")
    vp.add_argument("--home", required=True)
    vp.add_argument("--state", required=True)
    vp.add_argument("--force", action="store_true")

    lp = sub.add_parser("list-projects")
    lp.add_argument("--root", required=True)

    sl = sub.add_parser("sudo-list")
    sl.add_argument("--root", required=True)

    pl = sub.add_parser("publish-list")
    pl.add_argument("--root", required=True)

    pi = sub.add_parser("publish-info")
    pi.add_argument("project")
    pi.add_argument("--root", default="")

    # 项目身份 = 它相对工作区根的路径（ADR-0037）。就一行输出，给 shell 用
    # （init / move 要算身份）。工作区外面 → 非 0 退出，让调用方自己决定怎么说。
    pidp = sub.add_parser("project-id")
    pidp.add_argument("project")
    pidp.add_argument("--root", default="")

    pe = sub.add_parser("plan-env")
    pe.add_argument("--home", required=True)
    pe.add_argument("--state", required=True)
    pe.add_argument("--scratch", required=True)
    # 正在卸载的那个项目要从"还剩谁"里扣掉：它的 state 目录这会儿还在
    pe.add_argument("--exclude", default="")

    cl = sub.add_parser("claimed")
    cl.add_argument("--root", required=True)
    cl.add_argument("--home", required=True)
    cl.add_argument("--exclude-id", default="")

    pk = sub.add_parser("pack-plan")
    pk.add_argument("project")
    pk.add_argument("--scratch", required=True)

    stt = sub.add_parser("status")
    stt.add_argument("--root", required=True)
    stt.add_argument("--state", required=True)
    stt.add_argument("--color", default="auto")
    stt.add_argument("project")
    wd = sub.add_parser("write-dist")
    wd.add_argument("--out", required=True)
    wd.add_argument("--rows", required=True)
    wd.add_argument("--project-id", required=True)
    wd.add_argument("--tag", required=True)
    wd.add_argument("--repo", required=True)
    wd.add_argument("--commit", default="")
    wd.add_argument("--at", default="")
    wd.add_argument("--volume-size", default=DEFAULT_VOLUME_SIZE)
    wd.add_argument("--declare", default="")

    rt = sub.add_parser("release-targets")
    rt.add_argument("project_dir")

    dt = sub.add_parser("docker-targets")
    dt.add_argument("project_dir")

    dp = sub.add_parser("docker-plan")
    dp.add_argument("project_dir")
    dp.add_argument("--target", default="")
    # --rebuild：计划**内容不变**（还是这份层清单），它改的是执行期对着 docker /
    # __layer/ / __output/ 三条"已经好了"判据时要不要跳过。计划侧必须认这个 flag ——
    # 不认的话 `wtool build --rebuild` 走到这里就是 argparse 报错，
    # 表现成"加了开关但动作被静默丢弃"（AGENTS.md 那条：新增动作要同时改两边）。
    dp.add_argument("--rebuild", action="store_true")

    rj = sub.add_parser("release-json")
    rj.add_argument("--release-dir", required=True)
    rj.add_argument("--dist", default="")
    rj.add_argument("--project-id", default="")
    rj.add_argument("--engine", default="")
    rj.add_argument("--at", default="")
    rj.add_argument("--dirty", default="0")
    rj.add_argument("--targets", default="")

    dd = sub.add_parser("download-doc")
    dd.add_argument("--rows", required=True)
    dd.add_argument("--release-dir", default="")
    dd.add_argument("--tag", required=True)
    dd.add_argument("--repo", required=True)
    dd.add_argument("--project-id", required=True)
    dd.add_argument("--at", default="")

    ck = sub.add_parser("check")
    ck.add_argument("--root", required=True)
    ck.add_argument("--home", required=True)
    ck.add_argument("--state", required=True)
    ck.add_argument("project", nargs="?")

    kp = sub.add_parser("kill-plan")
    kp.add_argument("--home", required=True)
    kp.add_argument("--state", required=True)

    rd = sub.add_parser("read-dist")
    rd.add_argument("dist")

    ud = sub.add_parser("update-downloads")
    ud.add_argument("--doc", required=True)
    ud.add_argument("--rows", required=True)

    ppk = sub.add_parser("provision-packages")
    ppk.add_argument("playbook")

    tb = sub.add_parser("table")
    tb.add_argument("--root", required=True)
    tb.add_argument("--state", required=True)
    tb.add_argument("--verbose", action="store_true")
    # 颜色默认按是不是终端自动判断；给个开关是为了能测——
    # "项目提供了脚本"和"引擎通用机制能办"的区别只在颜色上
    tb.add_argument("--color", choices=("auto", "always", "never"), default="auto")
    tb.add_argument("--summary", action="store_true")
    # --brief：只打能力表 + 图例 + 汇总行（`wtool doctor` 和 bootstrap 末尾用）
    tb.add_argument("--brief", action="store_true")
    return p


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        if args.cmd == "plan-install":
            if not args.project:
                raise PlanError("plan-install 需要 <project-dir>")
            res = plan_install(args, args.scratch)
            for w in res["warnings"]:
                print("wtool: warning: %s" % w, file=sys.stderr)
            n_link = sum(1 for r in res["rows"] if r[0] == "link")
            n_home = sum(1 for r in res.get("home_rows", []) if r[0] == "link")
            n_rc = sum(1 for r in res["rows"] if r[0] in ("rc", "envblock"))
            n_prune = sum(1 for r in res["rows"] if r[0] in ("prune", "prune-dir"))
            print("project   : %s" % res["project_id"])
            print("root      : %s" % res["project_root"])
            print("actions   : %d link, %d home-link, %d rc" % (n_link, n_home, n_rc))
            if n_prune:
                print("prune     : %d 条（清单里已经没有）" % n_prune)
        elif args.cmd == "plan-uninstall":
            res = plan_uninstall(args, args.scratch)
            for w in res["warnings"]:
                print("wtool: warning: %s" % w, file=sys.stderr)
            print("project   : %s" % res["project_id"])
            print("actions   : %d rc" % sum(1 for r in res["rows"] if r[0] == "rc"))
        elif args.cmd == "plan-provision":
            res = plan_provision(args, args.scratch)
            for w in res["warnings"]:
                print("wtool: warning: %s" % w, file=sys.stderr)
            print("project   : %s" % res["project_id"])
            print("actions   : %d sysfile, %d source, %d task"
                  % (len(res["sysfiles"]), len(res["sources"]), len(res["tasks"])))
        elif args.cmd == "provision-packages":
            provision_packages(args)
        elif args.cmd == "list-projects":
            list_projects(args.root)
        elif args.cmd == "sudo-list":
            sudo_list(args.root)
        elif args.cmd == "publish-list":
            publish_list(args.root)
        elif args.cmd == "publish-info":
            return publish_info(args.project, args.root or None)
        elif args.cmd == "project-id":
            return cmd_project_id(args.project, args.root or None)
        elif args.cmd == "plan-env":
            rows = plan_env(args, args.scratch)
            _write_plan(args.scratch, rows)
            print("actions   : %d" % len(rows))
        elif args.cmd == "claimed":
            for dest, pid in claimed_homes(args.root, args.exclude_id, args.home):
                print("%s\t%s" % (dest, pid))
        elif args.cmd == "pack-plan":
            res = pack_plan(args)
            print("source    : %d 个文件" % len(res["source"]))
            print("release   : %d 个文件" % len(res["release"]))
            print("declare   : %s" % (",".join(res["declare"]) or "-"))
            print("declare_file\t%s" % os.path.join(args.scratch, "declare.tsv"))
        elif args.cmd == "status":
            # 不做彩色：status 是"给你看依据"的，格子值本来就那六个词，一眼能认
            lines, rc = project_status(args.root, args.state, args.project)
            for ln in lines:
                print(ln)
            return rc
        elif args.cmd == "write-dist":
            dist = write_dist(args)
            print("dist      : %s（%d 个文件，%d 个分卷）"
                  % (args.out, len(dist["files"]), len(dist["volumes"])))
        elif args.cmd == "release-targets":
            print(release_targets(args.project_dir))
        elif args.cmd == "docker-targets":
            try:
                for tgt, img in docker_targets(args.project_dir):
                    print("%s\t%s" % (tgt, img))
            except ValueError as exc:
                sys.stderr.write("error: %s\n" % exc)
                return 1
        elif args.cmd == "docker-plan":
            try:
                names = [t for t, _ in docker_targets(args.project_dir)]
                if not args.target:
                    sys.stderr.write("error: 要 --target=<目标>；这个项目声明了: %s\n"
                                     % ", ".join(names))
                    return 1
                if args.target not in names:
                    sys.stderr.write("error: 没有这个目标: %s（有 %s）\n"
                                     % (args.target, ", ".join(names)))
                    return 1
                layers = docker_layers(args.project_dir)
                imgs = dict((l, img) for l, _p, img, _c in layers)
                for layer, parent, image, cmd in docker_plan_order(layers):
                    ref = "-" if image == "-" else "%s:%s" % (image, args.target)
                    # 父层给的是**镜像引用** —— 引擎要用它起容器。
                    # 父层 `-` 的空格留给引擎填目标的基础镜像。
                    pref = "-" if parent == "-" else "%s:%s" % (imgs.get(parent, "-"),
                                                               args.target)
                    print("%s\t%s\t%s\t%s" % (layer, pref, ref,
                                                cmd.replace("{target}", args.target)))
            except ValueError as exc:
                sys.stderr.write("error: %s\n" % exc)
                return 1
        elif args.cmd == "release-json":
            release_json(args)
        elif args.cmd == "download-doc":
            download_doc(args)
        elif args.cmd == "check":
            return do_check(args)
        elif args.cmd == "kill-plan":
            return kill_plan(args)
        elif args.cmd == "read-dist":
            return read_dist(args)
        elif args.cmd == "update-downloads":
            # 内容从 stdout 出，由 shell 落盘（Python 只算不写）
            update_downloads(args.doc, args.rows)
            return 0
        elif args.cmd == "table":
            if args.color == "always":
                _color = True
            elif args.color == "never":
                _color = False
            else:
                _color = None
            if args.brief:
                # 只打能力表 + 图例 + 汇总行（doctor / bootstrap 末尾用）
                lines, _projects = render_dashboard(
                    args.root, args.state, verbose=False, color=_color, brief=True)
                for line in lines:
                    print(line)
            elif args.summary and not args.verbose:
                # `--summary` 单独用 = 只要那一行汇总（脚本用；doctor 走 --brief）
                projects = []
                for prio, pid, path, pub in scan_projects(args.root, manifests_only=True):
                    st = project_state(path, args.state, root=args.root)
                    st["prio"], st["path"], st["pub"] = prio, path, pub
                    st["cells"] = pipeline_states(path, pub, st)
                    projects.append(st)
                print(table_summary(projects))
            else:
                lines, _projects = render_dashboard(
                    args.root, args.state, verbose=args.verbose, color=_color)
                for line in lines:
                    print(line)
        elif args.cmd == "validate":
            errors, warnings = [], []
            root = os.path.abspath(args.project)
            meta, entries = parse_manifest(os.path.join(root, "wtool.xml"), root,
                                           errors, warnings)
            if meta is not None:
                validate_entries(entries, root, args.home, args.state, errors, warnings)
            for w in warnings:
                print("warning: %s" % w)
            for e in errors:
                print("error: %s" % e, file=sys.stderr)
            if errors:
                return 1
            print("ok: %s" % args.project)
    except PlanError as exc:
        print("wtool: error: %s" % exc, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

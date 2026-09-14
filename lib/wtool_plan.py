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
import os
import re
import sys
import xml.etree.ElementTree as ET

ENGINE_VERSION = "1.0.0"
SCHEMA_SUPPORTED = (1,)
DEFAULT_PRIORITY = 100

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


def parse_manifest(path, project_root, errors):
    """解析 wtool.xml（支持 include）。返回 (meta, entries)。"""
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

    default_prio = _int_attr(root, "priority", DEFAULT_PRIORITY, errors, "wtool")
    meta = {
        "schema": schema,
        "id": root.get("id") or None,
        "priority": default_prio,
        "manifest_path": path,
        "manifest_sha": sha256_text(text),
    }

    entries = []
    _parse_children(root, project_root, path, meta, entries, errors, depth=0)
    return meta, entries


def _parse_children(node, project_root, manifest_path, meta, entries, errors, depth):
    if depth > 8:
        errors.append("include 嵌套超过 8 层，疑似循环: %s" % manifest_path)
        return

    for child in node:
        tag = child.tag
        if tag == "env":
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

        elif tag == "link":
            src = child.get("src")
            dest = child.get("dest")
            if not src or not dest:
                errors.append("<link> 必须同时有 src 和 dest（%s）" % manifest_path)
                continue
            entries.append(Entry("link", src, dest=dest,
                                 force=_bool_attr(child, "force"),
                                 optional=_bool_attr(child, "optional"),
                                 manifest=manifest_path))

        elif tag == "system-file":
            # 写 $HOME 之外的系统文件（换源等）。可逆：备份→写；卸载时还原。
            dest = child.get("dest")
            # dest="auto" 只允许和 kind 一起用：由引擎按发行版算出目标路径
            if dest != "auto" and (not dest or not dest.startswith("/")):
                errors.append("<system-file> 的 dest 必须是绝对路径（或 kind 配 dest=\"auto\"）（%s）"
                              % manifest_path)
                continue
            if dest == "auto" and not child.get("kind"):
                errors.append("<system-file> dest=\"auto\" 必须和 kind 一起用")
                continue
            src = child.get("src")
            kind = child.get("kind")
            mode = (child.get("mode") or "replace").strip()
            if mode not in ("replace", "add", "disable"):
                errors.append("<system-file> mode 只能是 replace/add/disable，实际 %r" % mode)
                continue
            # disable 只是把原文件改名，不需要内容
            if mode != "disable" and not src and not kind:
                errors.append("<system-file> 需要 src（自己的内容）或 kind（引擎生成）")
                continue
            entries.append(Entry("sysfile", src or "", dest=dest, mode=mode,
                                 sf_kind=kind, mirror=child.get("mirror") or "ustc",
                                 backup=_bool_attr(child, "backup", default=(mode == "replace")),
                                 when=child.get("when") or "",
                                 desc=child.get("desc") or "",
                                 manifest=manifest_path))

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
                            errors, depth + 1)

        else:
            errors.append("未知元素 <%s>（%s）；自定义元素请用 x-* 前缀"
                          % (tag, manifest_path))


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
APT_MIRRORS = {
    "ustc": "https://mirrors.ustc.edu.cn/ubuntu/",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/",
    "aliyun": "https://mirrors.aliyun.com/ubuntu/",
}
DEB_MIRRORS = {
    "ustc": "https://mirrors.ustc.edu.cn/debian/",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn/debian/",
    "aliyun": "https://mirrors.aliyun.com/debian/",
}
YUM_MIRRORS = {
    "ustc": "https://mirrors.ustc.edu.cn",
    "tuna": "https://mirrors.tuna.tsinghua.edu.cn",
    "aliyun": "https://mirrors.aliyun.com",
}


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
        # 只有 env / link / task 的 src 是"项目内相对路径"；
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

        if entry.kind == "link":
            if not is_safe_rel(entry.dest):
                errors.append("link dest=%r 必须是相对 $HOME、不含 .. 的路径"
                              % entry.dest)
                continue
            abs_dest = os.path.join(home, entry.dest)
            if not is_under(abs_dest, home):
                errors.append("link dest 逃出 $HOME: %s" % entry.dest)
                continue
            if abs_dest in seen_dest:
                errors.append("同一个清单里 dest 重复: %s" % entry.dest)
                continue
            seen_dest[abs_dest] = entry
            entry.abs_dest = abs_dest
            entry.abs_src = abs_src

        elif entry.kind == "env":
            if entry.shells:
                entry.rc_files = [os.path.join(home, RC_FILE_BY_SHELL[s])
                                  for s in entry.shells if s in RC_CAPABLE_SHELLS]
            else:
                entry.rc_files = []
            entry.abs_src = abs_src

    # 跨仓冲突：registry 里 dest 被别的项目占了
    registry = _read_registry(os.path.join(state_dir, "registry.tsv"))
    return registry


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
    link_dir = '"$HOME/.wtool/links/%s"' % project_id
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
def plan_install(args, scratch):
    project_root = os.path.abspath(args.project)
    home = os.path.abspath(args.home)
    state_dir = os.path.abspath(args.state)

    errors, warnings = [], []
    manifest_path = os.path.join(project_root, "wtool.xml")
    meta, entries = parse_manifest(manifest_path, project_root, errors)
    if meta is None:
        raise PlanError("\n".join(errors))

    project_id = meta["id"] or os.path.relpath(project_root, os.environ.get("WTOOL_ROOT", project_root))
    if project_id in (".", "/"):
        project_id = os.path.basename(project_root)
    if not is_safe_rel(project_id):
        errors.append("项目 id 非法: %r" % project_id)

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
    link_dir = os.path.join(home, ".wtool", "links", project_id)
    for entry in entries:
        if entry.kind != "link" or getattr(entry, "skip", False):
            continue
        dest = entry.abs_dest
        want = os.path.join(link_dir, entry.src)
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

    rows = []

    def add_link(kind, dest, target):
        """reg 行始终发出（保持 registry 与磁盘一致）；
        link 行只在软链缺失/指向不对时才发出，这样重复 install 才是真正的 no-op。"""
        rows.append(("reg", kind, dest, "", "", ""))
        want = os.path.normpath(target)
        if os.path.islink(dest) and os.path.normpath(os.readlink(dest)) == want:
            return
        rows.append(("link", kind, dest, target, "", ""))

    # 1) 稳定中转链接 ~/.wtool/links/<id> -> <project_root>
    add_link("dir", link_dir, project_root)

    # 2) 项目内的软链，全部经由中转链接，保证仓库可搬家
    for entry in entries:
        if entry.kind != "link" or getattr(entry, "skip", False):
            continue
        add_link("file", entry.abs_dest, os.path.join(link_dir, entry.src))

    # 3) rc 注入
    rc_index = 0
    desired = {}  # rcfile -> env_rel
    for entry in entries:
        if entry.kind != "env" or getattr(entry, "skip", False):
            continue
        for rc in entry.rc_files:
            desired[rc] = entry.src

    all_rc = sorted(set(desired) | set(_rcs_with_our_block(home, project_id)))
    for rc in all_rc:
        env_rel = desired.get(rc)
        block = None
        if env_rel is not None:
            block = render_block(project_id, meta["schema"], meta["priority"],
                                 args.head, meta["manifest_sha"], env_rel)
        old = read_text(rc)
        new_text, removed_sha, changed = merge_rc(old, project_id, block,
                                                  meta["priority"], env_rel is None)
        if not changed:
            continue
        rc_file = os.path.join(scratch, "rc.%d" % rc_index)
        with open(rc_file, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(new_text)
        rc_index += 1
        new_block_sha = sha256_text("\n".join(block) + "\n") if block else "-"
        rows.append(("rc", "file", rc, rc_file, sha256_text(new_text), new_block_sha))

    _write_plan(scratch, rows)
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
        "warnings": warnings,
    }


def plan_uninstall(args, scratch):
    home = os.path.abspath(args.home)
    project_root = os.path.abspath(args.project) if args.project else None
    errors, warnings = [], []

    project_id = args.id
    if project_id is None:
        if not project_root:
            raise PlanError("uninstall 需要 <project-dir> 或 --id")
        manifest_path = os.path.join(project_root, "wtool.xml")
        meta, _ = parse_manifest(manifest_path, project_root, errors)
        if meta is None:
            raise PlanError("\n".join(errors))
        project_id = meta["id"] or os.path.basename(project_root)
    if not is_safe_rel(project_id):
        raise PlanError("项目 id 非法: %r" % project_id)

    rows = []
    rc_index = 0
    for rc in sorted(_rcs_with_our_block(home, project_id)):
        old = read_text(rc)
        new_text, removed_sha, changed = merge_rc(old, project_id, None,
                                                  DEFAULT_PRIORITY, True)
        if not changed:
            continue
        rc_file = os.path.join(scratch, "rc.%d" % rc_index)
        with open(rc_file, "w", encoding="utf-8", errors="surrogateescape") as fh:
            fh.write(new_text)
        rc_index += 1
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


def plan_provision(args, scratch):
    """规划 provision：system-file → source → task 三个阶段。"""
    project_root = os.path.abspath(args.project)
    home = os.path.abspath(args.home)
    state_dir = os.path.abspath(args.state)
    errors, warnings = [], []
    os.makedirs(scratch, exist_ok=True)

    manifest_path = os.path.join(project_root, "wtool.xml")
    meta, entries = parse_manifest(manifest_path, project_root, errors)
    if meta is None:
        raise PlanError("\n".join(errors))

    project_id = meta["id"] or os.path.basename(project_root)
    if not is_safe_rel(project_id):
        errors.append("项目 id 非法: %r" % project_id)

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
                content, dest_hint = render_distro_mirror(
                    entry.sf_kind, args.os_id, args.os_codename, entry.mirror, errors)
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


def _write_plan(scratch, rows):
    os.makedirs(scratch, exist_ok=True)
    with open(os.path.join(scratch, "plan.tsv"), "w",
              encoding="utf-8", errors="surrogateescape") as fh:
        for row in rows:
            fh.write("\t".join(row) + "\n")


def _write_meta(scratch, mapping):
    os.makedirs(scratch, exist_ok=True)
    with open(os.path.join(scratch, "meta.tsv"), "w", encoding="utf-8") as fh:
        for key, value in mapping.items():
            fh.write("%s\t%s\n" % (key, value))


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def list_projects(root):
    """扫描工作区里所有 wtool.xml，按 (priority, id) 排序输出。"""
    root = os.path.abspath(root)
    found = []
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
        found.append((meta["priority"], meta["id"] or os.path.basename(dirpath), dirpath))
        dirnames[:] = []          # 项目内部不再嵌套项目
    for prio, pid, path in sorted(found):
        print("%d\t%s\t%s" % (prio, pid, path))


def build_parser():
    p = argparse.ArgumentParser(prog="wtool_plan.py", add_help=True)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp, need_project=True):
        if need_project:
            sp.add_argument("project", nargs="?")
        sp.add_argument("--home", required=True)
        sp.add_argument("--state", required=True)
        sp.add_argument("--scratch", required=True)
        sp.add_argument("--id")
        sp.add_argument("--head", default="")
        sp.add_argument("--at", default="")
        sp.add_argument("--force", action="store_true")

    ip = sub.add_parser("plan-install")
    common(ip)
    up = sub.add_parser("plan-uninstall")
    common(up)
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
            n_rc = sum(1 for r in res["rows"] if r[0] == "rc")
            print("project   : %s" % res["project_id"])
            print("root      : %s" % res["project_root"])
            print("actions   : %d link, %d rc" % (n_link, n_rc))
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
        elif args.cmd == "list-projects":
            list_projects(args.root)
        elif args.cmd == "validate":
            errors, warnings = [], []
            root = os.path.abspath(args.project)
            meta, entries = parse_manifest(os.path.join(root, "wtool.xml"), root, errors)
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

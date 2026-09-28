#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""wtool_zip —— 打包/解包工具（引擎执行层调用，不是规划器）。

为什么不用系统的 `zip` 命令：这台机器上的 Info-ZIP **不设 UTF-8 名字标志**
（实测 `zip -UN=UTF8 源码.txt` 出来的条目 flag_bits=0，用别的工具解开是乱码），
而我们的归档名里有中文（`源码.zip` / `release.zip`）。python3 的 zipfile 是
标准库（引擎本来就依赖 python3），会正确设置 UTF-8 标志，还顺带解决了
"权限位要不要留住"（output 里的可执行文件必须留住）。

它和 tar/gzip 一样只是个**工具**：由 lib/wtool_fs.sh 调用，
只写调用方指定的路径，自己不做任何决定。

用法：
  wtool_zip.py create  <out.zip> <base-dir> <list-file>
      列表文件里是相对 base-dir 的路径（一行一个），必须已按名排序 ——
      这样同样的树打出来的字节是一样的。
  wtool_zip.py extract <zip> <dest-dir>
      按 zip 里的路径铺开；拒绝 .. 与绝对路径；还原 unix 权限位；
      软链条目按软链建（跟随软链打包的包不受影响）。
"""

import os
import stat
import sys
import zipfile

# 打包时间固定成 zip 能表达的最早时间：归档里不该有"什么时候打的"，
# 那样同样的内容每次打出来字节不同（依赖它算 sha256 的分卷就对不上了）。
FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def die(msg):
    sys.stderr.write("wtool_zip: error: %s\n" % msg)
    return 1


def safe_join(dest, name):
    """zip 里的路径 -> 落点；越界（..、绝对路径、盘符）返回 None。"""
    name = name.replace("\\", "/")
    if name.startswith("/") or (len(name) > 1 and name[1] == ":"):
        return None
    parts = [p for p in name.split("/") if p not in ("", ".")]
    if any(p == ".." for p in parts):
        return None
    if not parts:
        return None
    return os.path.join(dest, *parts)


def do_create(out, base, listfile, prefix="", extras=()):
    with open(listfile, encoding="utf-8", errors="surrogateescape") as fh:
        names = [line.rstrip("\n") for line in fh if line.strip()]
    if not names and not extras:
        return die("文件列表是空的: %s" % listfile)
    tmp = out + ".tmp.%d" % os.getpid()
    entries = [(prefix + n, os.path.join(base, n)) for n in names]
    # --extra 给的是**包内完整路径**，不再加前缀
    entries += [(arc, src) for arc, src in extras]
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED,
                         compresslevel=9) as zf:
        for arc, src in entries:
            if not os.path.lexists(src):
                os.unlink(tmp)
                return die("列表里的文件不存在: %s" % src)
            info = zipfile.ZipInfo(arc, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            if os.path.islink(src):
                # **软链要留着是软链**，不是跟着它把内容拷一份：
                # 源码树里 themes/x.zsh-theme -> real.zsh-theme 这种相对链，
                # 拷成实体文件之后目录结构和链接关系就没了
                # （tar 时代踩过：--transform 连指向一起改写，解压全是断链）。
                target = os.readlink(src)
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                zf.writestr(info, target.encode("utf-8", "surrogateescape"))
                continue
            st = os.lstat(src)          # 不跟随：权限位用文件自己的
            info.external_attr = (stat.S_IMODE(st.st_mode) & 0xFFFF) << 16
            if os.path.isdir(src):
                info.external_attr |= 0x10
                zf.writestr(info, b"")
                continue
            with open(src, "rb") as fh:
                zf.writestr(info, fh.read())
    os.replace(tmp, out)
    return 0


def do_extract(archive, dest):
    if not os.path.isfile(archive):
        return die("包不存在: %s" % archive)
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = safe_join(dest, info.filename)
            if target is None:
                return die("包里有越界路径，拒绝解开: %s" % info.filename)
            mode = (info.external_attr >> 16) & 0xFFFF
            if info.is_dir() or stat.S_ISDIR(mode):
                os.makedirs(target, exist_ok=True)
                continue
            if stat.S_ISLNK(mode):
                link_to = zf.read(info).decode("utf-8", "surrogateescape")
                if os.path.lexists(target):
                    os.unlink(target)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                os.symlink(link_to, target)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with zf.open(info) as src, open(target, "wb") as fh:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    fh.write(chunk)
            if mode:
                os.chmod(target, stat.S_IMODE(mode))
    return 0


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[0]
    if cmd == "create":
        if len(argv) < 4:
            return die("用法: create <out.zip> <base-dir> <list-file> "
                       "[--prefix=P] [--extra <abs-path> <arcname>]...")
        out, base, listfile = argv[1], argv[2], argv[3]
        prefix, extras, i = "", [], 4
        while i < len(argv):
            if argv[i] == "--prefix" or argv[i].startswith("--prefix="):
                if "=" in argv[i]:
                    prefix = argv[i].split("=", 1)[1]
                    i += 1
                else:
                    prefix = argv[i + 1]
                    i += 2
            elif argv[i] == "--extra":
                if i + 2 >= len(argv):
                    return die("--extra 需要 <绝对路径> <包内路径>")
                extras.append((argv[i + 2], argv[i + 1]))
                i += 3
            else:
                return die("不认识的参数: %s" % argv[i])
        return do_create(out, base, listfile, prefix, extras)
    if cmd == "extract":
        if len(argv) != 3:
            return die("用法: extract <zip> <dest-dir>")
        return do_extract(argv[1], argv[2])
    return die("未知子命令: %s" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/bin/sh
# provision 层自测：system-file（换源）/ source（wsw.sh 编译型）/ task
# 全程在临时目录里跑，不碰真实 $HOME、不碰 /etc、不需要 root。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
boot=$(dirname -- "$here")

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "期望 [$2]  实际 [$3]"; }

newenv() {
    # 注意：必须在当前 shell 里调用（不能写成 newenv，子 shell 会丢掉 export）
    H=$(mktemp -d "${TMPDIR:-/tmp}/wtool-prov.XXXXXX")
    mkdir -p "$H/home" "$H/prefix" "$H/src" "$H/upstream"
    export WTOOL_HOME="$H/home"
    export WTOOL_STATE="$H/state"
    export WTOOL_PREFIX="$H/prefix"
    export WTOOL_SRC="$H/src"
}

mkrepo() { # mkrepo <目录> <id> ；wtool.xml 由调用方随后写
    d=$1
    mkdir -p "$d"
    ( cd "$d" && git init -q && git -c user.email=t@example.com -c user.name=t \
        commit -q --allow-empty -m init )
}

commit() {
    ( cd "$1" && git add -A && git -c user.email=t@example.com -c user.name=t \
        commit -qm "${2:-update}" )
}

# --------------------------------------------------------------------------
printf '\n== 场景 1：system-file replace + 备份 + 还原 ==\n'
newenv
sys="$H/system/etc/apt/sources.list.d"
mkdir -p "$sys"
printf '原来的源\n' > "$sys/test.sources"
p="$H/proj1"; mkrepo "$p"
printf 'Types: deb\nURIs: https://mirrors.ustc.edu.cn/ubuntu/\n' > "$p/mirror.sources"
cat > "$p/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="os/test" priority="5">
  <system-file src="mirror.sources" dest="$sys/test.sources" mode="replace" backup="true"/>
</wtool>
EOF
commit "$p"

# 第一次故意不加 --with-system：应当被跳过
"$boot/wtool.sh" provision "$p" > "$H/p1.log" 2>&1 || bad "provision 执行" "$(cat "$H/p1.log")"
check "未加 --with-system 时不动系统" "原来的源" "$(cat "$sys/test.sources")"
grep -q '跳过系统文件' "$H/p1.log" && ok "提示了需要 --with-system" \
    || bad "提示了需要 --with-system" "$(cat "$H/p1.log")"

"$boot/wtool.sh" provision "$p" --with-system > "$H/p1b.log" 2>&1 || bad "provision --with-system" "$(cat "$H/p1b.log")"
check "加 --with-system 后写入新内容" \
      "$(printf 'Types: deb\nURIs: https://mirrors.ustc.edu.cn/ubuntu/')" "$(cat "$sys/test.sources")"

"$boot/wtool.sh" uninstall "$p" > "$H/u1.log" 2>&1 || bad "uninstall" "$(cat "$H/u1.log")"
check "uninstall 后从备份还原" "原来的源" "$(cat "$sys/test.sources")"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 2：system-file add（原来不存在）→ 卸载后删除 ==\n'
newenv
sys="$H/system/etc/apt/sources.list.d"
mkdir -p "$sys"
p="$H/proj2"; mkrepo "$p"
printf '新增的源\n' > "$p/extra.sources"
cat > "$p/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="os/extra" priority="5">
  <system-file src="extra.sources" dest="$sys/extra.sources" mode="add"/>
</wtool>
EOF
commit "$p"
"$boot/wtool.sh" provision "$p" --with-system > /dev/null 2>&1 || true
[ -f "$sys/extra.sources" ] && ok "新文件已创建" || bad "新文件已创建"
"$boot/wtool.sh" uninstall "$p" > /dev/null 2>&1 || true
[ ! -f "$sys/extra.sources" ] && ok "卸载后文件被删除（原本不存在）" \
    || bad "卸载后文件被删除（原本不存在）" "$(cat "$sys/extra.sources" 2>/dev/null)"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 3：system-file disable（把官方源改名禁用）==\n'
newenv
sys="$H/system/etc/apt/sources.list.d"
mkdir -p "$sys"
printf '官方源\n' > "$sys/ubuntu.sources"
p="$H/proj3"; mkrepo "$p"
cat > "$p/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="os/disable" priority="5">
  <system-file dest="$sys/ubuntu.sources" mode="disable"/>
</wtool>
EOF
commit "$p"
"$boot/wtool.sh" provision "$p" --with-system > /dev/null 2>&1 || true
[ ! -e "$sys/ubuntu.sources" ] && [ -e "$sys/ubuntu.sources.wtool-disabled" ] \
    && ok "官方源已改名禁用" || bad "官方源已改名禁用" "$(ls "$sys")"
"$boot/wtool.sh" uninstall "$p" > /dev/null 2>&1 || true
[ -e "$sys/ubuntu.sources" ] && ok "卸载后改回原名" || bad "卸载后改回原名" "$(ls "$sys")"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 4：kind=apt-mirror 自动生成 deb822 源 ==\n'
newenv
sys="$H/system/etc/apt/sources.list.d"
mkdir -p "$sys"
p="$H/proj4"; mkrepo "$p"
cat > "$p/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="os/auto" priority="5">
  <system-file kind="apt-mirror" mirror="ustc" dest="$sys/ubuntu.sources"
               mode="replace" backup="true"/>
</wtool>
EOF
commit "$p"
"$boot/wtool.sh" provision "$p" --with-system > "$H/p4.log" 2>&1 \
    || bad "kind=apt-mirror 执行" "$(cat "$H/p4.log")"
got=$(cat "$sys/ubuntu.sources")
case $got in
    *"Types: deb"*) : ;;
    *) bad "自动生成内容含 Types: deb" "$got" ;;
esac
case $got in
    *"Suites: noble noble-updates noble-backports noble-security"*) : ;;
    *) bad "自动识别出 codename=noble" "$got" ;;
esac
case $got in
    *"mirrors.ustc.edu.cn"*) ok "自动生成 deb822（识别出 ubuntu/noble）" ;;
    *) bad "自动生成 deb822（识别出 ubuntu/noble）" "$got" ;;
esac
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 5：source（clone → 固定 ref → 建 wsw 分支 → 铺 overlay）==\n'
newenv
up="$H/upstream"; mkdir -p "$up"
( cd "$up" && git init -q && git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
  printf 'v1\n' > file.txt
  git add -A && git -c user.email=t@e -c user.name=t commit -qm v1
  git tag v1.0 )
printf 'v2\n' > "$up/file.txt"
( cd "$up" && git add -A && git -c user.email=t@e -c user.name=t commit -qm v2 )

p="$H/proj5"; mkrepo "$p"
mkdir -p "$p/overlay"
printf '#!/bin/sh\necho "built" > "$WTOOL_PREFIX/built.txt"\nprintf "%%s" "$WTOOL_SOURCE_REF" > "$WTOOL_PREFIX/ref.txt"\n' > "$p/overlay/wsw.sh"
chmod +x "$p/overlay/wsw.sh"
cat > "$p/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="build/test" priority="70">
  <source url="$up" ref="v1.0" dir="$H/src/test" branch="wsw" overlay="overlay"/>
  <provision src="wsw.sh" marker="test-{ref}" desc="测试编译"/>
</wtool>
EOF
commit "$p"

"$boot/wtool.sh" provision "$p" > "$H/p5.log" 2>&1 || bad "source+task 执行" "$(cat "$H/p5.log")"
srcdir="$H/src/test"
check "源码已 clone 到指定目录" "v1" "$(cat "$srcdir/file.txt")"
check "已切到固定 ref" "v1.0" "$(git -C "$srcdir" describe --tags --abbrev=0 2>/dev/null)"
check "本地分支为 wsw" "wsw" "$(git -C "$srcdir" rev-parse --abbrev-ref HEAD)"
[ -f "$srcdir/wsw.sh" ] && ok "overlay 已铺进源码树" || bad "overlay 已铺进源码树"
check "任务写到了 \$WTOOL_PREFIX" "built" "$(cat "$H/prefix/built.txt" 2>/dev/null)"
check "任务拿到了 WTOOL_SOURCE_REF" "v1.0" "$(cat "$H/prefix/ref.txt" 2>/dev/null)"
[ -f "$H/state/build/test/provisioned/test-{ref}" ] \
    && ok "marker 已记录（幂等）" || bad "marker 已记录（幂等）" "$(ls "$H/state/build/test" 2>/dev/null)"

# 第二次：marker 命中应跳过任务
rm -f "$H/prefix/built.txt"
"$boot/wtool.sh" provision "$p" > "$H/p5b.log" 2>&1
grep -q '已装过' "$H/p5b.log" && ok "第二次 provision 跳过任务" \
    || bad "第二次 provision 跳过任务" "$(cat "$H/p5b.log")"
[ ! -f "$H/prefix/built.txt" ] && ok "任务确实没重跑" || bad "任务确实没重跑"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 6：--dry-run 零副作用 ==\n'
newenv
sys="$H/system/etc"
mkdir -p "$sys"
printf '原始\n' > "$sys/x.conf"
p="$H/proj6"; mkrepo "$p"
printf '新的\n' > "$p/x.conf"
cat > "$p/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="dry/test" priority="5">
  <system-file src="x.conf" dest="$sys/x.conf" mode="replace" backup="true"/>
  <source url="$H/upstream" ref="v1.0" dir="$H/src/dry"/>
  <provision src="x.conf" marker="dry" desc="不该执行"/>
</wtool>
EOF
commit "$p"
"$boot/wtool.sh" provision "$p" --with-system --dry-run > "$H/p6.log" 2>&1 \
    || bad "dry-run 执行" "$(cat "$H/p6.log")"
check "dry-run 不动系统文件" "原始" "$(cat "$sys/x.conf")"
[ ! -d "$H/src/dry" ] && ok "dry-run 不 clone 源码" || bad "dry-run 不 clone 源码"
grep -q 'dry-run' "$H/p6.log" && ok "dry-run 输出了计划" || bad "dry-run 输出了计划"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 7：list-projects 按 priority 排序 ==\n'
newenv
mkdir -p "$H/ws/a" "$H/ws/b" "$H/ws/c"
for spec in "a 50" "b 10" "c 30"; do
    set -- $spec
    cat > "$H/ws/$1/wtool.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="x/$1" priority="$2"/>
EOF
done
got=$(python3 "$boot/lib/wtool_plan.py" list-projects --root "$H/ws" | cut -f2 | tr '\n' ' ')
check "按 priority 排序" "x/b x/c x/a " "$got"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n== 场景 8：when 条件过滤（os:ubuntu）==\n'
newenv
p="$H/proj8"; mkrepo "$p"
printf 'x\n' > "$p/x.conf"
cat > "$p/wtool.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<wtool schema="1" id="when/test" priority="5">
  <system-file src="x.conf" dest="$H/system/x.conf" mode="replace"
               when="os:ubuntu" desc="只在 ubuntu 上做"/>
</wtool>
XML
commit "$p"
got=$(python3 "$boot/lib/wtool_plan.py" plan-provision "$p" --home "$H/home" \
        --state "$H/state" --scratch "$H/sc1" --os-id ubuntu --os-codename noble \
        --arch x86_64 --src-root "$H/src" 2>&1 | tail -1)
check "ubuntu 上匹配" "actions   : 1 sysfile, 0 source, 0 task" "$got"
got=$(python3 "$boot/lib/wtool_plan.py" plan-provision "$p" --home "$H/home" \
        --state "$H/state" --scratch "$H/sc2" --os-id debian --os-codename bookworm \
        --arch x86_64 --src-root "$H/src" 2>&1 | tail -1)
check "debian 上跳过" "actions   : 0 sysfile, 0 source, 0 task" "$got"
rm -rf "$H"

# --------------------------------------------------------------------------
printf '\n----------------------------------------\n'
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1

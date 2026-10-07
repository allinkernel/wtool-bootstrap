# 下载 bootstrap

这一版：`ds_dev-2026-10-07`（2026-10-08）

| 文件 | 大小 | 是什么 | 直链 |
|---|---|---|---|
| `dist.json` | 923B | — | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-07/dist.json |
| `release-hash.txt` | 78B | — | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-07/release-hash.txt |
| `release.zip` | 2.2K | 产物包 | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-07/release.zip |
| `source-hash.txt` | 77B | — | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-07/source-hash.txt |
| `source.zip` | 343.2K | 源码包 | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-07/source.zip |

## 怎么装

**装了 wtool 的机器**（推荐，校验和拼分卷它自己做）：

```sh
wtool download-release bootstrap   # 按仓库里提交的 scripts/release.json 下载 + 校验
wtool unpack-release bootstrap     # 拼分卷 + 解到 __output/
wtool install bootstrap            # 装到本机（登记、软链、shell 集成）
```

**只有浏览器的机器**：把上面每个文件点下来，放进项目的 `__release/` 目录，
再在那台机器上跑后两条命令 —— `unpack-release` 认包里的 `dist.json`，
缺了哪一卷它会说清楚。

`install` 只认 `release.zip`（产物包），不需要 `source.zip`。

---

> ⚠️ **这份页面里的名字是「线上真实名字」。** 引擎打的源码包在本地的名字是
> `源码.zip` / `源码-hash.txt`，而 **GitHub 不接受非 ASCII 的资产名** —— 上传时被改写成了
> `source.zip` / `source-hash.txt`（内容一个字节没变，sha256 与 `dist.json` 里的记录一致）。
> 后果有两条：
>
> 1. `wtool download-release <项目>` 读的是 `scripts/release.json` 里记的 `源码.zip`，
>    所以它会报两条「这个文件没下来」。**不影响安装** —— `install` 只消费 `release.zip`。
> 2. 想要源码包：在发布页下 `source.zip`，放进本项目的 `__release/` 并**改名回 `源码.zip`**，
>    再跑 `wtool unpack-release <项目>`，它就会连源码包一起校验。
>
> 根治办法是让引擎改用一个 ASCII 的资产名（见 `harness/BACKLOG.md`）。

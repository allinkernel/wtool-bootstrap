# 下载 bootstrap

这一版：`ds_dev-2026-10-09`（2026-10-09）

| 文件 | 大小 | 是什么 | 直链 |
|---|---|---|---|
| `dist.json` | 859B | — | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-09/dist.json |
| `source-hash.txt` | 77B | — | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-09/source-hash.txt |
| `source.zip` | 353.2K | 源码包 | https://github.com/allinkernel/wtool-bootstrap/releases/download/ds_dev-2026-10-09/source.zip |

## 怎么装

**装了 wtool 的机器**（推荐，校验和拼分卷它自己做）：

```sh
wtool download-release bootstrap   # 按仓库里提交的 scripts/release.json 下载 + 校验
wtool unpack-release bootstrap     # 拼分卷 + 把源码铺回项目目录
wtool install bootstrap            # 装到本机（登记、软链、shell 集成）
```

**只有浏览器的机器**：把上面每个文件点下来，放进项目的 `__release/` 目录，
再在那台机器上跑后两条命令 —— `unpack-release` 认包里的 `dist.json`，
缺了哪一卷它会说清楚。

这一版**只有源码包**：这个项目没有构建产物（没有 `scripts/build.sh`、
也没有 `build/layers.tsv`），源码就是产物 ——
`unpack-release` 会把源码铺回项目目录，`install` 照常装。

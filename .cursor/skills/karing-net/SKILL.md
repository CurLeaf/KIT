---
name: karing-net
description: >-
  本机 Karing / 系统代理 / Cursor 出网运维：跑 D:\KIT\karing-net\karing-net.ps1
  的 status、watch、sync、restart。
  Use when the user asks 网络、通畅、代理、运维、Karing、karing-net、系统代理、
  TUN、extension-host、连不上、超时、3057、3067, YouTube, 浏览器, or names
  status / sync / restart / watch. Skip when editing unrelated KIT tools,
  or when the user only wants a git commit.
---

# karing-net 运维

对用户说简体中文。本机网络只走这一套，不另开脚本。

实现或改 `karing-net/` 代码走 `/execute`。本层是运维，不 commit。

## 入口

`D:\KIT\karing-net\karing-net.ps1`

| 命令 | 做什么 |
|---|---|
| `status` | 进程 + `127.0.0.1:3057` / `3067`。`-Api` 读并打印组名 |
| `watch` | 计划任务每分钟：快照；Cursor 换组记下旧节点，满 5 分钟才按 id 关仍挂在旧链上的连接；URLTest 组不 PUT；手动满 30 分钟回 urltest |
| `sync` | 画像漂移才写盘，不重启。画像含 auto_select 容差 150 / 健康检查 300s，三池 regex 不变，diversion 四车道（AI / Cursor / 直连 / 自动优选），final 走自动优选；国外穿墙匹配器不含 geosite:google。写盘后要核心按新规则工作必须 restart，由 Karing 编译 service_core，禁止手改该文件。 |
| `restart` | 停 `karing` / `karingService`，拉计划任务 `Karing`，等端口 |

登录任务 `Karing` 只负责拉起 `karing.exe`。`watch` 看到 3057 没齐就 `skip=ports`。

## 怎么选命令

先 `status -Api`。端口齐但组空、画像漂、浏览器走不动 → `sync`。核心假死或 sync 后仍不通 → `restart`。锁冲突退出码 3：停下，不要重试、不要再开一套。

```
powershell -NoProfile -ExecutionPolicy Bypass -File D:\KIT\karing-net\karing-net.ps1 status -Api
```

不要跑已 retired 的 `apply_recommended_net.ps1`、`manual_to_auto.ps1`。不要 `-FlushConnections`、无 id 的 `DELETE /connections`。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | `status` 两端口齐；`sync`/`restart` 成功 |
| 1 | `status` 端口未齐；`sync`/`restart` 失败 |
| 3 | 锁冲突 |

## 回报

先给本轮命令全文和退出码，再说是否通。不要用「应该通了」代替输出。

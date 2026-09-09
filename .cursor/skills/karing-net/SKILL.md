---
name: karing-net
description: >-
  本机 Karing / 系统代理 / Cursor 出网运维：只跑 D:\KIT\karing-net\karing-net.ps1
  的 status、watch、sync、restart。默认只 status；sync 与 restart 须用户当句点名。
  Use when the user asks 网络、通畅、代理、运维、Karing、karing-net、系统代理、
  TUN、extension-host、连不上、超时、3057、3067, or names status / sync / restart / watch.
  Skip when editing unrelated KIT tools, or when the user only wants a git commit.
---

# karing-net 运维

对用户说简体中文。本机网络只走这一套，不另开脚本、不拿外网当验收。

实现或改 `karing-net/` 代码走 `/execute`。本层是运维，不 commit。

## 何时用 / 跳过

**用**：探活、排网、代理是否在听、Cursor / extension-host 出网、用户问这套怎么管、点名四命令之一。

**跳过**：其它目录的功能开发；只要求提交；用户没提网络 / Karing / 代理。

## 入口

`D:\KIT\karing-net\karing-net.ps1`

| 命令 | 谁触发 | 做什么 |
|---|---|---|
| `status` | 人手；默认可跑 | 进程 + `127.0.0.1:3057` / `3067`。`-Api` 只读组名 |
| `watch` | 计划任务每分钟 | 快照；Cursor 换组则按 id 关连接；踢信息节点；手动满 30 分钟回 urltest |
| `sync` | 用户当句写 `sync` | 画像漂移才写盘，不重启 |
| `restart` | 用户当句写 `restart` | 停 `karing` / `karingService`，拉计划任务 `Karing`，等端口 |

登录任务 `Karing` 只负责拉起 `karing.exe`。`watch` 看到 3057 没齐就 `skip=ports`，不会在核心没起来时改连接。

## 默认只 status

```
powershell -NoProfile -ExecutionPolicy Bypass -File D:\KIT\karing-net\karing-net.ps1 status
```

需要组名再加 `-Api`。探活只报进程和这两个端口，不要 `curl` / `Invoke-WebRequest` 走 `127.0.0.1:3067`，不要访问 `api2.cursor.sh`。

## 点名才 sync / restart

用户这句话里没有 `sync` / `restart` 这两个词：只 `status`，然后说明要纠画像或重启须点名。

点名了再跑对应命令。锁冲突退出码 3：停下，不要重试，不要再开一套。

## 禁止

- `%APPDATA%\karing\karing\apply_recommended_net.ps1`、`manual_to_auto.ps1`（已 retired，exit 2）
- `-FlushConnections`、无 id 的 `DELETE /connections`、任何「timeout recovery」整表清空
- 用户未点名时重启 `karing.exe` / `karingService.exe`，或 `-ForceRestart`

## 退出码

| 码 | 含义 |
|---|---|
| 0 | `status` 两端口齐；`sync`/`restart` 成功 |
| 1 | `status` 端口未齐；`sync`/`restart` 失败 |
| 3 | 锁冲突 |

## 回报

先给本轮命令全文和退出码，再说是否通。不要用「应该通了」代替输出。

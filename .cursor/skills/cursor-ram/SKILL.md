---
name: cursor-ram
description: >-
  本机 Cursor 内存余量：只跑 D:\KIT\cursor-ram\cursor-ram.ps1 的
  status、apply、watch、hold、pack、park、purge、install。
  默认只 status；其余须用户当句点名。
  Use when the user asks 内存、腾空间、Docker Desktop、vmmemWSL、
  native-preview、cursor-ram, or names status / apply / watch / hold /
  pack / park / purge / install in this context. Skip when editing
  unrelated KIT tools, or when the user only wants a git commit.
---

# cursor-ram 运维

对用户说简体中文。内存余量只走这一套，不另开脚本，不关 Cursor 窗口，不杀 Cursor.exe。

实现或改 `cursor-ram/` 代码走 `/execute`。本层是运维，不 commit。

## 何时用 / 跳过

**用**：查空闲内存 / Desktop 残留 / WSL 泄漏、收 WSL、打包前后 hold/pack、一次 purge 卸 Desktop。

**跳过**：其它目录功能开发；只要求提交；用户没提内存或 Docker 常驻。

## 入口

`D:\KIT\cursor-ram\cursor-ram.ps1`

| 命令 | 谁触发 | 做什么 |
|---|---|---|
| `status` | 人手；默认可跑 | 策略快照。齐 → 0 |
| `apply` | 当句点名 | 无 hold 则收 WSL；挪走 Playwright MCP；删 native-preview 目录 |
| `watch` | 登录 + 每 15 分钟；或当句 | 无 hold 且非 build → 收 WSL。不改扩展/mcp |
| `hold` | 当句点名 | 默认 2 小时 |
| `pack` | 当句点名 | 起 Ubuntu docker、自动 hold、在 WSL 跑剩余参数、再 apply |
| `park` | 当句点名 | `-Dev` 才停 vinext/uni/Playwright Chrome |
| `purge` | 当句点名 | 卸 Desktop、删 VHDX、写 `.wslconfig` 3GB/4 核。约 85GB 缓存不可恢复 |
| `install` | 当句点名 | Desktop 残留则失败并提示 purge；否则注册 watch、装 Windows `docker.exe`（转到 Ubuntu docker，不暴露 2375）并 apply |

## 默认只 status

```
powershell -NoProfile -ExecutionPolicy Bypass -File D:\KIT\cursor-ram\cursor-ram.ps1 status
```

## 点名才 apply / watch / hold / pack / park / purge / install

用户这句话里没有这些词：只 `status`。锁冲突退出码 3：停下，不要重试。

`bun docker` / `bun run docker` 走 Windows 上的 `docker.exe`（`%LOCALAPPDATA%\KIT\cursor-ram\bin`）：shim 按当前目录 `wsl --cd` 进 Ubuntu 跑 docker，不必再包一层 `pack`。新开的终端才能看到 PATH。第一次推送先 `docker login`。

## 禁止

- 关 Cursor 窗口或 `Stop-Process Cursor.exe`
- 没点名就 `purge` / `apply` / `pack`
- 把 dockerd 挂到 `2375` 或 `0.0.0.0`
- 为了本机 Redis/Postgres 把 Desktop 装回来

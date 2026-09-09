---
name: cursor-update
description: >-
  本机 Cursor 无感更新：只跑 D:\KIT\cursor-update\cursor-update.ps1 的
  status、fetch、apply、watch、install。默认只 status；fetch / apply /
  watch / install 须用户当句点名。
  Use when the user asks Cursor 更新、无感更新、Toast 更新、安装包、
  落后官方版本, or names status / fetch / apply / watch / install in this
  context. Skip when editing unrelated KIT tools, or when the user only
  wants a git commit.
---

# Cursor 无感更新

对用户说简体中文。更新只走这一套，不开 Cursor 内置 `silentlyApplyOnQuit`，不写 Plugin / 扩展。

实现或改 `cursor-update/` 代码走 `/execute`。本层是运维，不 commit。

## 何时用 / 跳过

**用**：查本机 Cursor 是否落后、安装包在不在、弹更新 Toast、点更新、装计划任务。

**跳过**：其它目录功能开发；只要求提交；用户没提 Cursor 更新。

## 入口

`D:\KIT\cursor-update\cursor-update.ps1`

| 命令 | 谁触发 | 做什么 |
|---|---|---|
| `status` | 人手；默认可跑 | 读本机 `product.json` + 缓存 `latest.json` / 包。不联网 |
| `fetch` | 用户当句写 `fetch` | 问 `cursor.com/api/download`，按下本机 user/system 种类下对应安装包到 `%LOCALAPPDATA%\KIT\cursor-update\` |
| `watch` | 计划任务每小时 + 登录时；或当句 `watch` | 该下就 fetch；包已齐且 Cursor 在跑且未 Toast 过这一版 → 右下角 Toast |
| `apply` | Toast 点击 / 当句 `apply` | 脱离后关掉全部 `Cursor.exe`，对真实安装目录静默安装（不用 `/update=`），删包，再拉起 |
| `install` | 当句 `install`（建议管理员） | 协议 `cursor-update://`、每小时 / 登录 watch 与按需 apply 任务、`update.mode=none` |

## 默认只 status

```
powershell -NoProfile -ExecutionPolicy Bypass -File D:\KIT\cursor-update\cursor-update.ps1 status
```

## 点名才 fetch / apply / watch / install

用户这句话里没有这些词：只 `status`。锁冲突退出码 3：停下，不要重试。

## 禁止

- 访问 `api2.cursor.sh`
- `/CLOSEAPPLICATIONS`、内置 `silentlyApplyOnQuit`
- 没点名就 `apply`（watch 不准安装）
- 用 `/update=` 去更新空的 `C:\Program Files\cursor`
- 给本机 User 安装下 system-setup（或反过来）

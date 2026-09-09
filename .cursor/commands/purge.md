---
name: /purge
id: purge
category: Workflow
description: 清空 design/execute 方案树，以及仓库里未入仓的测试文件
---

执行本命令即授权立刻清空本地方案与测试残留，**不要再确认**。本层不 commit。

## 做什么

在仓库根跑：

```powershell
powershell.exe -NoProfile -File scripts/Purge.ps1
```

脚本是 `scripts/Purge.ps1`（对齐 erp-admin-1 `scripts/purge.ts`，本仓不引入 bun）：

- 整棵删除：`.superpowers/`（含 `plans/` 实现方案与 `w<波次>-t<任务>` 会话文件）
- 整棵删除（若存在）：`openspec/`、`tests/`、`design/`、`.cursor/plans/`
- 全仓删除未入仓的：`*.test.ts` / `*.test.tsx`、`*.Tests.ps1`、`*_test.py`、`*_test.js`，以及 `__test__` / `_test_` / `__tests__` 夹具目录
- 保留：git 已跟踪的测试（如 `karing-net/KaringNet.Tests.ps1`、`goal-board/engine_test.js`、`compress-wsl-disk/compress.Tests.ps1`）
- 跳过：`node_modules`、`.git`、构建缓存目录；不碰 `docs/`

## 回合

1 个工具回合：跑上面的命令，把全文输出贴回对话。数一下删了多少 path。不要读方案正文、不要改业务代码、不要 `git add` / commit。

无残留时脚本仍会打印 `skip (missing)` / `purged 0 path(s)`，这也算完成。

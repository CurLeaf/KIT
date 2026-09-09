---
name: /git-commit
id: git-commit
category: Workflow
description: 凭 staged diff 补缺注 + 只检 staged + 中文 commit 并默认推送；最多 3 个工具回合
---

执行本命令即授权 **`git commit` 与 `git push`**。用户说「只 commit 不 push」则跳过 push。

对齐 erp-admin-1 `.cursor/commands/git-commit.md`；本仓不引入 bun / biome，不要发明 `bun run check`。

## 回合预算（硬限制）

整次命令 **最多 3 个工具回合**，禁止再开「规划下一轮 / 再读一遍 / 再确认」。

| 回合 | 并行做什么 | 禁止 |
|------|------------|------|
| 1 | `git status` + `git diff` + `git diff --staged` + `git log -5 --oneline`，随即 `git add -A` | codegraph、通读源文件、读 `.cursor/skills/**` / require-ana |
| 2 | **只看** `git diff --cached` 判注释；缺关键点才打开**那一个**文件改注释。不要跑 biome / bun / 全仓测试 | 整文件通读、发明 bun/biome、为换行去改 git config |
| 3 | 写中文 message → `git commit` → 若落后则 `git pull --rebase` → `git push` → `git status` | push 后再考古 merge 图；再跑检查 / unittest / Pester |

`status` 已同步或 push 完成 **立即停**。无变更则不空提交。

## 安全约束

- 禁止改 git config；禁止 `push --force` / `reset --hard`（除非用户明确要求）；禁止对 `main`/`master` force push。
- 禁止 `--no-verify` 等跳过 hook。
- 禁止 amend（除非用户明确要求，且 HEAD 本会话创建、且未 push）。
- 禁止提交 `.env` / 凭证。
- **禁止** commit message 含 `Co-authored-by:`、`Made-with: Cursor`、任何 Cursor trailer；禁止 `--trailer`。

## 1. 状态与暂存

```bash
git status
git diff
git diff --staged
git log -5 --oneline
git add -A
```

一次提交工作区全部改动，不按功能拆 commit。

## 2. 注释（只改注释，且尽量不改）

范围：`git diff --cached --name-only` 的 `.py` / `.ps1` / `.js`。排除锁文件、配置、`*.md`、`.cursor/**`、`.claude/**`、生成物。删除-only 的文件跳过。

**只凭 staged diff 判断。** 导出函数 / 跨目录约定 / 非显而易见分支 / 数据字段缺业务含义才补一句中文；已有且正确则 **零改动**。禁止为注释再 Read/codegraph 已在 diff 里的文件。

用语：简体中文；不抄类型；不写教程。实现疑似有错只报告、不改逻辑。

改过注释则 `git add` 那些文件。

## 3. 检查（只检 staged，禁止全仓）

**不要** `bun` / `biome` / `bun run check`。本仓无 formatter gate，不要发明。

也不要借机跑 `python -m unittest` / `Invoke-Pester` / 全仓验收（那是 `/execute`）。

实现疑似有错只报告、不改逻辑。无 staged 代码文件 → 跳过。

## 4. Commit message

只根据 **已看过的** staged stat / diff 写 **一条** 中文：

```
type(scope): 简短中文描述
```

`type`：`feat` / `fix` / `refactor` / `chore` / `docs` / `style` / `test`。多主题用概括 subject + 正文列表。禁止英文 subject。

PowerShell：

```powershell
$msg = @"
type(scope): 简短中文描述
"@
git commit -m $msg
```

## 5. 推送并结束

```bash
git pull --rebase
git push
git status
```

无 upstream 时 `git push -u origin HEAD`。rebase 冲突则停并报告，不要 force push。hook 失败则修问题后 **新 commit**，不要 amend。

`status` 显示与远程同步、工作区干净 → **结束**。不要再 `git log --graph`。

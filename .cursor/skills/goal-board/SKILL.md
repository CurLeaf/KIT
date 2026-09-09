---
name: goal-board
description: >-
  维护 goal-board 静态目标看板：每日一份 JSON、今日只读当天文件、三列现代看板、engine 纯函数。
  Use when working on goal-board, 目标看板, goals.json, 每日 JSON, 或 data/YYYY-MM-DD.json.
---

# Goal Board

对用户说简体中文。不引入 bun / Vite / React / Prisma。不自动 `git commit`。实现走 `/execute`（`.cursor/skills/execute/SKILL.md`）。

每天的 json 数据都是不同的 json，并且今日只用当前的 json。

## 何时用 / 跳过

**用**：改 `goal-board/`、写或改当日目标数据、问看板怎么跑 / 数据放哪。

**跳过**：其它工具目录；用户只要提交（本层不 commit）。

## 数据

- 一天一个文件：`goal-board/data/YYYY-MM-DD.json`（本地日历日）。
- 看板只 `fetch` `GoalEngine.todayDataPath()`，即今日文件。
- 禁止回退到昨天或其它日期。今日文件缺失就让加载失败。
- 禁止再写 `data/goals.json`。
- 禁止把多日文件合并进今日视图。
- 从昨天开今日：复制昨天文件为今日文件名，再改今日内容，并更新 `meta.updatedAt`。

`schemaVersion` 保持 `"1.0"`。`id` / `status` / `target.type` 保持英文；标题、负责人角色、`update.text`、`activities[].text`、`meta.title` / `period` 用中文。

`status`：`at_risk` | `on_track` | `completed`。  
`target.type`：`duration` | `percentage` | `count` | `milestone` | `boolean`。

排序只调 `sortGoals`。列分桶只调 `goalsByStage`。不要按 owner 分组或排序。`completed` 不进三列。

## 代码边界

| 改 | 测 |
|---|---|
| `engine.js` 行为 | 先红后绿：`goal-board/engine_test.js`，`node --test goal-board/engine_test.js` |
| `app.js` / `index.html` / `styles.css` | Select-String 锚点；改脚本后给 `index.html` 的 `?v=` 加一 |
| 只改当日 JSON | 确认路径是今日 `YYYY-MM-DD`；不改 Engine |

Viewer 只拉今日 JSON，并调用：`todayDataPath` `sortGoals` `goalsByStage` `summarize` `shouldReplace`。不要恢复鼓轮准星、`data-phase` 切屏、`location.reload()`、FOCUS 侧栏。

禁止 `linear-gradient`、字重 700/800、20px+ 圆角。不要恢复软木纹、胶带、图钉或鼓轮准星。

## 本地看

在 `goal-board/`：

```
python serve.py
```

http://127.0.0.1:8765/

## 验收

宣称做完前本轮跑：

```
node --test goal-board/engine_test.js
```

文档 / skill 用 Select-String 钉住「今日只用当前的 json」与 `todayDataPath`。

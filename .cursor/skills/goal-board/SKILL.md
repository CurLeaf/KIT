---
name: goal-board
description: >-
  维护 goal-board 静态目标看板：每日一份 JSON、今日只读当天文件、文件缩略图进树形图、engine 纯函数。
  Use when working on goal-board, 目标看板, goals.json, 每日 JSON, 或 data/YYYY-MM-DD.json.
---

# Goal Board

对用户说简体中文。不引入 bun / Vite / React / Prisma。不自动 `git commit`。实现走 `/execute`（`.cursor/skills/execute/SKILL.md`）。

每天的 json 数据都是不同的 json，并且今日只用当前的 json。首页是文件缩略图，点进去是树形图；树按 JSON 编排。

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

`schemaVersion` 保持 `"1.1"`。非 1.1 或没有 `projects` 时加载失败，不要读旧 `goals[]`。

`id` / `status` / `stage` 保持英文；标题、负责人角色、`update.text`、`meta.title` / `period` 用中文。

结构：`projects[]`（一张文件缩略图）→ `features[]`（目标节点树，可再嵌套 `features`）→ `tasks[]`（挂在节点上的工作项，画成同一套卡片）。点进项目后是左根右展逻辑图，画布拖拽平移、滚轮缩放，不要滚轴。折叠点在父节点右侧连线上。有下级的节点可点击展开或收起：默认展开含子目标的节点，仅有工作项的叶子默认收起。工具栏「全部折叠」收起所有可折叠节点，「全部展开」打开全部含下级或工作项的节点。不再用虚线卡片或角标区分「节点 / 进度」。同层上下 = JSON 数组顺序，`treeChildren` 只返回 `features`，`nodeProcessings` 返回 `tasks`。缩略图预览走 `previewTree`（默认 `maxDepth` 2、`maxChildren` 4）。目标叶子 `progress` 为 `0` 或 `1`；非叶子用 `nodeProgress` 对子孙目标叶子求和。工作项自己的 `progress` 也是 `0`/`1`。风险用颜色，不靠重排。节点底色按进度一眼可辨：`0` 白底灰边，部分完成青绿底加粗边和进度条，全部完成实心青绿白字。已完成留在树里，不要变灰藏掉。

`status`：`at_risk` | `on_track` | `completed`。  
`stage`：`discuss` | `develop` | `accept`（数据字段，不是列）。

`sortProjects` / `sortFeatures` / `sortGoals` 仍留在 engine，供测试与其它调用。已完成留在树里（实心青绿），不要藏掉。

## 代码边界

| 改 | 测 |
|---|---|
| `engine.js` 行为 | 先红后绿：`goal-board/engine_test.js`，`node --test goal-board/engine_test.js` |
| `app.js` / `index.html` / `styles.css` | Select-String 锚点；改脚本后给 `index.html` 的 `?v=` 加一 |
| 只改当日 JSON | 确认路径是今日 `YYYY-MM-DD`；不改 Engine |

Viewer 只拉今日 JSON，并调用：`todayDataPath` `readProjects` `treeChildren` `nodeProcessings` `previewTree` `nodeProgress` `nodeLeafCount` `flattenTasks` `descendantTasks` `rollupProgress` `rollupStatus` `summarize` `shouldReplace` `isNodeOpen` `foldableIds` `setAllCollapsed` `mapLayout` `mapLinkPath` `panCam` `zoomCam`。不要恢复三列看板、鼓轮准星、`data-phase` 切屏、`location.reload()`、FOCUS 侧栏。

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

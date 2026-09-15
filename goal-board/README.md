# 目标看板

静态页，无构建。首页是今日项目的文件缩略图；点进去是树形图。每天的 json 数据都是不同的 json，并且今日只用当前的 json。

## 启动

在 `goal-board/` 下：

```
python serve.py
```

打开 http://127.0.0.1:8765/ 。改 JS / CSS 后给 `index.html` 里的 `?v=` 加一。

## 每日数据

| 文件 | 含义 |
|---|---|
| `data/YYYY-MM-DD.json` | 那一天的完整快照 |
| 看板请求 | 只拉 `todayDataPath()`，即本地日历的 `data/今日.json` |

不要写 `data/goals.json`。不要把昨天或其它日期的文件拼进今日。今日文件不存在时看板显示无法加载，不回退到其它日期。

从昨天开今日：复制昨天的文件为今日文件名，再改今日内容。`meta.updatedAt` 必须改，否则 5 分钟刷新会认为没变化。

## 文件

| 路径 | 职责 |
|---|---|
| `index.html` | 页架 |
| `styles.css` | 文件缩略图 / 树形图 |
| `engine.js` | 纯函数，Node 与浏览器共用 |
| `engine_test.js` | `node --test` |
| `app.js` | 拉今日 JSON、文件网格与树视图 |
| `data/YYYY-MM-DD.json` | 当日数据 |

## JSON

`schemaVersion` 为 `"1.1"`。非 1.1 或没有 `projects` 时加载失败，不读旧 `goals[]`。

`id`、`status`、`stage` 保持英文；可见文案用中文。

结构：`projects[]` → `features[]`（目标节点，可再嵌套 `features`）→ `tasks[]`（该节点的处理/探索）。每个 project 是一张缩略图；点进去的树只画目标节点，始终展开。处理挂在节点上，可折叠。

同层左右顺序 = JSON 数组顺序。不要为了排版去改顺序。目标叶子进度为 `0` 或 `1`，非叶子显示子孙目标叶子之和。处理行也是 `0`/`1`。

`status`：`at_risk` / `on_track` / `completed`。

`stage`：`discuss` / `develop` / `accept`（数据字段，树节点上不画阶段列）。

进度写在目标叶子 `progress`（`0` 或 `1`）上，非叶子显示子孙目标叶子之和。处理是另一套数据，写在 `tasks` 里。已完成留在树里。

## 测试

```
node --test goal-board/engine_test.js
```

实现与改数据时按 `.cursor/skills/goal-board/SKILL.md`。

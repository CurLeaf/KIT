# 目标看板

静态页，无构建。三列现代看板（讨论 / 开发 / 验收）展示当日目标。每天的 json 数据都是不同的 json，并且今日只用当前的 json。

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
| `index.html` | 页架与三列 |
| `styles.css` | 三列卡片 |
| `engine.js` | 纯函数，Node 与浏览器共用 |
| `engine_test.js` | `node --test` |
| `app.js` | 拉今日 JSON、按阶段贴便签 |
| `data/YYYY-MM-DD.json` | 当日数据 |

## JSON

`schemaVersion` 为 `"1.0"`。`id`、`status`、`target.type` 保持英文；可见文案用中文。

`status`：`at_risk` / `on_track` / `completed`。

`target.type`：`duration` / `percentage` / `count` / `milestone` / `boolean`。

排序只走 `sortGoals`（风险在前），列分桶走 `goalsByStage`，不要按负责人分组。已完成不进三列。

## 测试

```
node --test goal-board/engine_test.js
```

`prefers-reduced-motion: reduce` 时不旋转便签。

实现与改数据时按 `.cursor/skills/goal-board/SKILL.md`。

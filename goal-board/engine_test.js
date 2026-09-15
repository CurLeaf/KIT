'use strict'

const { test } = require('node:test')
const assert = require('node:assert/strict')
const E = require('./engine.js')

const NOW = Date.parse('2026-09-05T15:32:00+08:00')

function goal(partial) {
  return {
    id: 'GOAL-000',
    title: 'x',
    owner: { id: 'u', name: '甲', role: 'R' },
    status: 'on_track',
    progress: 50,
    target: { type: 'number', value: 1 },
    current: { value: 1 },
    timeline: { startAt: '2026-07-01', dueAt: '2026-09-30' },
    update: { text: '', updatedAt: '2026-09-05T12:00:00+08:00' },
    activities: [],
    ...partial,
  }
}

test('sortGoals puts at_risk before on_track before completed', () => {
  const rows = E.sortGoals([
    goal({ id: 'C', status: 'completed', progress: 100 }),
    goal({ id: 'O', status: 'on_track', progress: 80 }),
    goal({ id: 'R', status: 'at_risk', progress: 40 }),
  ], NOW)
  assert.deepEqual(rows.map((g) => g.id), ['R', 'O', 'C'])
})

test('sortGoals does not group or sort by owner', () => {
  const rows = E.sortGoals([
    goal({
      id: 'GOAL-B',
      owner: { id: 'zhang', name: '张三', role: 'BE' },
      status: 'on_track',
      progress: 80,
      timeline: { startAt: '2026-07-01', dueAt: '2026-10-01' },
    }),
    goal({
      id: 'GOAL-A',
      owner: { id: 'zhang', name: '张三', role: 'BE' },
      status: 'at_risk',
      progress: 20,
      timeline: { startAt: '2026-07-01', dueAt: '2026-09-10' },
    }),
    goal({
      id: 'GOAL-C',
      owner: { id: 'li', name: '李四', role: 'FE' },
      status: 'on_track',
      progress: 10,
      timeline: { startAt: '2026-07-01', dueAt: '2026-09-20' },
    }),
  ], NOW)
  assert.deepEqual(rows.map((g) => g.id), ['GOAL-A', 'GOAL-C', 'GOAL-B'])
})

test('same status sorts by nearer dueAt then lower progress', () => {
  const rows = E.sortGoals([
    goal({ id: 'FAR', status: 'on_track', progress: 10, timeline: { startAt: '2026-07-01', dueAt: '2026-12-01' } }),
    goal({ id: 'NEAR-HI', status: 'on_track', progress: 90, timeline: { startAt: '2026-07-01', dueAt: '2026-09-08' } }),
    goal({ id: 'NEAR-LO', status: 'on_track', progress: 20, timeline: { startAt: '2026-07-01', dueAt: '2026-09-08' } }),
  ], NOW)
  assert.deepEqual(rows.map((g) => g.id), ['NEAR-LO', 'NEAR-HI', 'FAR'])
})

test('pickFocus prefers at_risk over higher-progress on_track', () => {
  const focus = E.pickFocus([
    goal({ id: 'OK', status: 'on_track', progress: 90, timeline: { startAt: '2026-07-01', dueAt: '2026-12-01' } }),
    goal({ id: 'RISK', status: 'at_risk', progress: 54, timeline: { startAt: '2026-07-01', dueAt: '2026-09-12' } }),
    goal({ id: 'DONE', status: 'completed', progress: 100 }),
  ], 3, NOW)
  assert.equal(focus[0].id, 'RISK')
  assert.ok(focus.length <= 3)
})

test('visibleGoalCount follows 1440/1920/4K density', () => {
  assert.equal(E.visibleGoalCount(1440), 6)
  assert.equal(E.visibleGoalCount(1920), 8)
  assert.equal(E.visibleGoalCount(2560), 10)
  assert.equal(E.visibleGoalCount(3840), 12)
})

test('paginate batches without scrolling remainder into previous page', () => {
  const pages = E.paginate(['a', 'b', 'c', 'd', 'e'], 2)
  assert.deepEqual(pages, [['a', 'b'], ['c', 'd'], ['e']])
  assert.deepEqual(E.paginate([], 6), [[]])
})

function project(partial) {
  return {
    id: 'proj-a',
    title: '模块甲',
    features: [],
    ...partial,
  }
}

function feature(partial) {
  return {
    id: 'feat-a',
    title: '功能甲',
    owner: { id: 'u', name: '甲', role: '工程' },
    features: [],
    tasks: [],
    ...partial,
  }
}

function task(partial) {
  return {
    id: 'TASK-1',
    title: '任务甲',
    status: 'on_track',
    progress: 40,
    stage: 'develop',
    update: { text: '进行中', updatedAt: '2026-09-15T10:00:00+08:00' },
    ...partial,
  }
}

test('readProjects rejects schema other than 1.1', () => {
  assert.throws(() => E.readProjects({ schemaVersion: '1.0', goals: [] }), /unsupported schema/)
  assert.throws(() => E.readProjects({ schemaVersion: '1.1' }), /unsupported schema/)
  assert.throws(() => E.readProjects(null), /unsupported schema/)
})

test('readProjects returns projects for schema 1.1', () => {
  const projects = [project()]
  assert.equal(E.readProjects({ schemaVersion: '1.1', projects }), projects)
})

test('flattenTasks walks nested features and stamps project path', () => {
  const projects = [
    project({
      id: 'proj-sup',
      title: '供应商系统',
      features: [
        feature({
          id: 'feat-form',
          title: '商品表单',
          owner: { id: 'w', name: '王书达', role: '工程' },
          tasks: [task({ id: 'TASK-1', title: '改校验' })],
          features: [
            feature({
              id: 'feat-sub',
              title: '子功能',
              owner: { id: 'l', name: '卢凯杰', role: '工程' },
              tasks: [task({ id: 'TASK-2', title: '联调', progress: 80 })],
            }),
          ],
        }),
      ],
    }),
  ]
  const rows = E.flattenTasks(projects)
  assert.deepEqual(rows.map((r) => r.id), ['TASK-1', 'TASK-2'])
  assert.equal(rows[0].projectId, 'proj-sup')
  assert.equal(rows[0].projectTitle, '供应商系统')
  assert.equal(rows[0].featureId, 'feat-form')
  assert.equal(rows[0].featureTitle, '商品表单')
  assert.equal(rows[0].featureOwner.name, '王书达')
  assert.equal(rows[1].featureId, 'feat-sub')
  assert.equal(rows[1].featureTitle, '子功能')
})

test('flattenTasks returns empty for missing projects', () => {
  assert.deepEqual(E.flattenTasks(), [])
  assert.deepEqual(E.flattenTasks([]), [])
})

test('descendantTasks collects nested feature tasks', () => {
  const f = feature({
    tasks: [task({ id: 'T1' })],
    features: [feature({ id: 'c', tasks: [task({ id: 'T2' })] })],
  })
  assert.deepEqual(E.descendantTasks(f).map((t) => t.id), ['T1', 'T2'])
})

test('rollupProgress averages task progress and treats empty as 0', () => {
  assert.equal(E.rollupProgress([]), 0)
  assert.equal(E.rollupProgress([task({ progress: 80 }), task({ progress: 40 })]), 60)
  assert.equal(E.rollupProgress([task({ progress: null }), task({ progress: 50 })]), 25)
})

test('rollupStatus prefers at_risk then completed only when all done', () => {
  assert.equal(E.rollupStatus([]), 'on_track')
  assert.equal(E.rollupStatus([task({ status: 'completed' }), task({ status: 'at_risk' })]), 'at_risk')
  assert.equal(E.rollupStatus([task({ status: 'completed' }), task({ status: 'completed' })]), 'completed')
  assert.equal(E.rollupStatus([task({ status: 'completed' }), task({ status: 'on_track' })]), 'on_track')
})

test('summarize reads project tree not flat goals', () => {
  const projects = [
    project({
      features: [
        feature({
          tasks: [
            task({ status: 'on_track', progress: 80 }),
            task({ status: 'on_track', progress: 60 }),
            task({ status: 'completed', progress: 100 }),
            task({ status: 'at_risk', progress: 40 }),
          ],
        }),
      ],
    }),
    project({ id: 'proj-b', title: '模块乙' }),
  ]
  assert.deepEqual(E.summarize(projects), {
    projects: 2,
    tasks: 4,
    total: 4,
    overall: 70,
    onTrack: 2,
    completed: 1,
    atRisk: 1,
  })
})

test('sortProjects puts at_risk and lower progress first', () => {
  const risk = project({
    id: 'P-RISK',
    features: [feature({ tasks: [task({ status: 'at_risk', progress: 90 })] })],
  })
  const slow = project({
    id: 'P-SLOW',
    features: [feature({ tasks: [task({ status: 'on_track', progress: 10 })] })],
  })
  const fast = project({
    id: 'P-FAST',
    features: [feature({ tasks: [task({ status: 'on_track', progress: 90 })] })],
  })
  assert.deepEqual(E.sortProjects([fast, risk, slow]).map((p) => p.id), ['P-RISK', 'P-SLOW', 'P-FAST'])
})

test('sortFeatures puts at_risk and lower progress first', () => {
  const risk = feature({ id: 'F-RISK', tasks: [task({ status: 'at_risk', progress: 80 })] })
  const slow = feature({ id: 'F-SLOW', tasks: [task({ status: 'on_track', progress: 10 })] })
  const fast = feature({ id: 'F-FAST', tasks: [task({ status: 'on_track', progress: 90 })] })
  assert.deepEqual(E.sortFeatures([fast, risk, slow]).map((f) => f.id), ['F-RISK', 'F-SLOW', 'F-FAST'])
})

test('formatTarget covers duration percentage count milestone boolean', () => {
  assert.equal(
    E.formatTarget({ type: 'duration', label: 'P95 latency', value: 30, unit: 'ms', operator: '<=' }),
    'P95 ≤ 30ms',
  )
  assert.equal(E.formatTarget({ type: 'percentage', value: 80 }), '80%')
  assert.equal(E.formatTarget({ type: 'count', label: 'Customers', value: 100 }), '100 Customers')
  assert.equal(E.formatTarget({ type: 'milestone', label: 'Core modules migrated', value: 10 }), 'Core modules migrated')
  assert.equal(E.formatTarget({ type: 'boolean', value: true }), '✓')
})

test('formatCurrent pairs with target type', () => {
  assert.equal(E.formatCurrent({ value: 42, unit: 'ms' }, { type: 'duration', unit: 'ms' }), '42ms')
  assert.equal(E.formatCurrent({ value: 67 }, { type: 'percentage' }), '67%')
  assert.equal(E.formatCurrent({ value: 7 }, { type: 'milestone', value: 10 }), '7 / 10')
  assert.equal(E.formatCurrent({ value: true }, { type: 'boolean' }), '✓')
})

test('formatRelativeTime uses m/h/d', () => {
  assert.equal(E.formatRelativeTime('2026-09-05T13:32:00+08:00', NOW), '2h ago')
  assert.equal(E.formatRelativeTime('2026-09-05T15:02:00+08:00', NOW), '30m ago')
  assert.equal(E.formatRelativeTime('2026-09-03T15:32:00+08:00', NOW), '2d ago')
})

test('recentActivities is Goal-bound and newest first', () => {
  const rows = E.recentActivities([
    goal({
      id: 'GOAL-024',
      owner: { id: '1', name: '张三', role: 'BE' },
      activities: [
        { type: 'pr_merged', text: '鉴权中间件迁移完成', at: '2026-09-05T13:32:00+08:00' },
      ],
    }),
    goal({
      id: 'GOAL-018',
      owner: { id: '2', name: '王五', role: 'Delivery' },
      activities: [
        { type: 'metric', text: '交付周期更新至 4.6 天', at: '2026-09-05T09:32:00+08:00' },
      ],
    }),
  ], 8)
  assert.deepEqual(rows.map((r) => r.goalId), ['GOAL-024', 'GOAL-018'])
  assert.equal(rows[0].ownerName, '张三')
})

test('shouldReplace keys off meta.updatedAt', () => {
  assert.equal(E.shouldReplace(null, { updatedAt: 'a' }), true)
  assert.equal(E.shouldReplace({ updatedAt: 'a' }, { updatedAt: 'a' }), false)
  assert.equal(E.shouldReplace({ updatedAt: 'a' }, { updatedAt: 'b' }), true)
})

test('advanceAutoScroll keeps subpixel carry until a full pixel', () => {
  const first = E.advanceAutoScroll(0, 500, 0, 16, 28)
  assert.equal(first.top, 0)
  assert.ok(first.carry > 0)
  let cur = first
  for (let i = 0; i < 10; i += 1) {
    cur = E.advanceAutoScroll(cur.top, 500, cur.carry, 16, 28)
  }
  assert.ok(cur.top >= 1)
})

test('wrapLoopScroll subtracts a cycle instead of jumping to zero', () => {
  assert.equal(E.wrapLoopScroll(400, 350), 50)
  assert.equal(E.wrapLoopScroll(350, 350), 0)
  assert.equal(E.wrapLoopScroll(50, 350), 50)
  assert.equal(E.wrapLoopScroll(100, 0), 100)
})

test('resumeAutoTop keeps going from the current thumb position', () => {
  assert.equal(E.resumeAutoTop(340, 360, 350, false), 10)
  assert.equal(E.resumeAutoTop(1400, 1416, 350, false), 1416)
  assert.equal(E.resumeAutoTop(1400, 1800, 350, true), 50)
  assert.equal(E.resumeAutoTop(80, 96, 350, false), 96)
})

test('sightRowIndex picks the slot nearest the sight line', () => {
  assert.equal(E.sightRowIndex(0, 200, 10), 0)
  assert.equal(E.sightRowIndex(99, 200, 10), 0)
  assert.equal(E.sightRowIndex(100, 200, 10), 1)
  assert.equal(E.sightRowIndex(200, 200, 10), 1)
  assert.equal(E.sightRowIndex(2000, 200, 10), 0)
  assert.equal(E.sightRowIndex(0, 0, 10), 0)
  assert.equal(E.sightRowIndex(200, 200, 0), 0)
})

test('drumPad centers one row in the viewport', () => {
  assert.equal(E.drumPad(600, 200), 200)
  assert.equal(E.drumPad(200, 200), 0)
  assert.equal(E.drumPad(100, 200), 0)
  assert.equal(E.drumRowHeight(600, 3), 200)
  assert.equal(E.drumRowHeight(601, 3), 200)
  assert.equal(E.drumCardHeight(), 128)
})

test('todayDataPath uses only the local calendar day', () => {
  assert.equal(E.todayDataPath(new Date(2026, 8, 6, 1, 15, 0)), 'data/2026-09-06.json')
  assert.equal(E.todayDataPath(new Date(2026, 8, 5, 23, 59, 0)), 'data/2026-09-05.json')
  assert.equal(E.todayDataPath(new Date(2026, 8, 9, 10, 18, 0)), 'data/2026-09-09.json')
  assert.notEqual(
    E.todayDataPath(new Date(2026, 8, 6, 0, 0, 0)),
    E.todayDataPath(new Date(2026, 8, 5, 0, 0, 0)),
  )
})

test('snapTop locks to the nearest card slot', () => {
  assert.equal(E.snapTop(0, 128), 0)
  assert.equal(E.snapTop(60, 128), 0)
  assert.equal(E.snapTop(64, 128), 128)
  assert.equal(E.snapTop(200, 128), 256)
  assert.equal(E.snapTop(90, 0), 90)
})

test('ratchetTop holds then eases to the next slot', () => {
  assert.deepEqual(E.ratchetTop(0, 128, 100, 2000, 400, 1280), { top: 0, done: false, wrapped: false })
  const mid = E.ratchetTop(0, 128, 2200, 2000, 400, 1280)
  assert.equal(mid.done, false)
  assert.equal(Math.round(mid.top), 64)
  assert.deepEqual(E.ratchetTop(0, 128, 2400, 2000, 400, 1280), { top: 128, done: true, wrapped: false })
  assert.deepEqual(E.ratchetTop(1152, 128, 2400, 2000, 400, 1280), { top: 0, done: true, wrapped: true })
})

test('goalsByStage buckets by stage and hides completed', () => {
  const rows = E.goalsByStage([
    goal({ id: 'D', stage: 'discuss', status: 'on_track' }),
    goal({ id: 'V', stage: 'develop', status: 'on_track' }),
    goal({ id: 'A', stage: 'accept', status: 'on_track' }),
    goal({ id: 'X', stage: 'develop', status: 'completed', progress: 100 }),
    goal({ id: 'R', stage: 'discuss', status: 'at_risk', progress: 10 }),
  ], NOW)
  assert.deepEqual(rows.discuss.map((g) => g.id), ['R', 'D'])
  assert.deepEqual(rows.develop.map((g) => g.id), ['V'])
  assert.deepEqual(rows.accept.map((g) => g.id), ['A'])
})

test('goalsByStage treats missing stage as discuss', () => {
  const rows = E.goalsByStage([
    goal({ id: 'N', status: 'on_track' }),
  ], NOW)
  assert.deepEqual(rows.discuss.map((g) => g.id), ['N'])
  assert.deepEqual(rows.develop, [])
  assert.deepEqual(rows.accept, [])
})

test('buildCycle and phaseLabel form a predictable loop', () => {
  const cycle = E.buildCycle(2, 3)
  assert.deepEqual(cycle.map((s) => s.phase), [
    'OVERVIEW', 'GOALS', 'GOALS', 'FOCUS', 'FOCUS', 'FOCUS', 'ACTIVITY',
  ])
  assert.equal(E.phaseLabel(cycle[0], cycle), 'OVERVIEW')
  assert.equal(E.phaseLabel(cycle[2], cycle), 'GOALS  ·  2 / 2')
  assert.equal(E.nextStepIndex(6, cycle), 0)
  assert.equal(E.stepDuration({ phase: 'GOALS', index: 0 }), 15000)
  assert.equal(E.PHASE_MS.OVERVIEW, 8000)
})

test('treeChildren lists only goal features in JSON order', () => {
  const parent = feature({
    features: [
      feature({ id: 'f-b', title: '后写' }),
      feature({ id: 'f-a', title: '先写' }),
    ],
    tasks: [
      task({ id: 'T-2', title: '任务乙' }),
      task({ id: 'T-1', title: '任务甲', status: 'at_risk' }),
    ],
  })
  const rows = E.treeChildren(parent)
  assert.deepEqual(rows.map((r) => [r.kind, r.item.id]), [
    ['feature', 'f-b'],
    ['feature', 'f-a'],
  ])
})

test('nodeProcessings lists processing rows not goal children', () => {
  const parent = feature({
    features: [feature({ id: 'f-a' })],
    tasks: [
      task({ id: 'T-2', title: '任务乙' }),
      task({ id: 'T-1', title: '任务甲' }),
    ],
  })
  assert.deepEqual(E.nodeProcessings(parent).map((t) => t.id), ['T-2', 'T-1'])
  assert.deepEqual(E.nodeProcessings(), [])
  assert.deepEqual(E.nodeProcessings(null), [])
})

test('treeChildren returns empty for missing parent', () => {
  assert.deepEqual(E.treeChildren(), [])
  assert.deepEqual(E.treeChildren(null), [])
})

test('previewTree caps depth and sibling count without reordering', () => {
  const p = project({
    id: 'p1',
    title: '根',
    features: [
      feature({
        id: 'f1',
        title: 'F1',
        owner: { id: 'u', name: '甲', role: '工程' },
        features: [feature({ id: 'deep', title: '深层', tasks: [task({ id: 'T-DEEP' })] })],
        tasks: [task({ id: 'T1' })],
      }),
      feature({ id: 'f2', title: 'F2' }),
      feature({ id: 'f3', title: 'F3' }),
      feature({ id: 'f4', title: 'F4' }),
      feature({ id: 'f5', title: 'F5' }),
    ],
  })
  const tree = E.previewTree(p, { maxDepth: 2, maxChildren: 4 })
  assert.equal(tree.kind, 'project')
  assert.equal(tree.id, 'p1')
  assert.equal(tree.title, '根')
  assert.equal(tree.children.length, 4)
  assert.equal(tree.omitted, 1)
  assert.deepEqual(tree.children.map((c) => c.id), ['f1', 'f2', 'f3', 'f4'])
  assert.equal(tree.children[0].ownerName, '甲')
  const f1 = tree.children[0]
  assert.deepEqual(f1.children.map((c) => c.id), ['deep'])
  assert.equal(f1.omitted, 0)
  const deep = f1.children[0]
  assert.equal(deep.id, 'deep')
  assert.deepEqual(deep.children, [])
  assert.equal(deep.omitted, 0)
})

test('previewTree defaults maxDepth 2 and maxChildren 4', () => {
  const features = []
  for (let i = 1; i <= 5; i += 1) {
    features.push(feature({ id: `f${i}`, title: `F${i}` }))
  }
  const tree = E.previewTree(project({ features }))
  assert.equal(tree.children.length, 4)
  assert.equal(tree.omitted, 1)
})

test('previewTree stamps leaf flag and goal progress', () => {
  const tree = E.previewTree(project({
    features: [
      feature({ id: 'f1', progress: 1 }),
      feature({ id: 'f2', progress: 0 }),
    ],
  }))
  assert.equal(tree.leaf, false)
  assert.equal(tree.progress, 1)
  assert.equal(tree.leafCount, 2)
  assert.equal(tree.children[0].leaf, true)
  assert.equal(tree.children[0].progress, 1)
  assert.equal(tree.children[1].progress, 0)
})

test('nodeProgress leaf is 0 or 1 on the goal node', () => {
  assert.equal(E.nodeProgress('task', task({ progress: 1 })), 1)
  assert.equal(E.nodeProgress('task', task({ progress: 0 })), 0)
  assert.equal(E.nodeProgress('task', task({ progress: 40 })), 0)
  assert.equal(E.nodeProgress('task', task({ progress: null })), 0)
  const leaf = feature({
    progress: 1,
    tasks: [task({ progress: 0 })],
  })
  assert.equal(E.nodeProgress('feature', leaf), 1)
  assert.equal(E.nodeLeafCount('feature', leaf), 1)
})

test('nodeProgress non-leaf sums child goal leaves not processings', () => {
  const f = feature({
    progress: 9,
    tasks: [task({ progress: 1 })],
    features: [
      feature({ id: 'a', progress: 1, tasks: [task({ progress: 0 })] }),
      feature({ id: 'b', progress: 0, tasks: [task({ progress: 1 })] }),
    ],
  })
  assert.equal(E.nodeProgress('feature', f), 1)
  assert.equal(E.nodeLeafCount('feature', f), 2)
})

test('nodeProgress nested features sum descendant goal leaves', () => {
  const f = feature({
    features: [
      feature({ id: 'a', progress: 1, tasks: [task({ progress: 0 })] }),
      feature({
        id: 'b',
        features: [
          feature({ id: 'c', progress: 1 }),
          feature({ id: 'd', progress: 0 }),
        ],
      }),
    ],
  })
  assert.equal(E.nodeProgress('feature', f), 2)
  assert.equal(E.nodeLeafCount('feature', f), 3)
  assert.equal(E.nodeLeafCount('task', task()), 1)
})

test('nodeCount counts all goal nodes not processings', () => {
  assert.equal(E.nodeCount('project', null), 0)
  assert.equal(E.nodeCount('task', task()), 0)
  assert.equal(E.nodeCount('project', project()), 0)
  const p = project({
    features: [
      feature({
        id: 'root',
        tasks: [task({ id: 'T-1' })],
        features: [
          feature({ id: 'a', tasks: [task({ id: 'T-2' })] }),
          feature({
            id: 'b',
            features: [
              feature({ id: 'c' }),
              feature({ id: 'd' }),
            ],
          }),
        ],
      }),
    ],
  })
  assert.equal(E.nodeCount('project', p), 5)
  assert.equal(E.nodeCount('feature', p.features[0]), 5)
  assert.equal(E.nodeCount('feature', p.features[0].features[0]), 1)
})

test('nodeFill is zero part or full from goal progress', () => {
  assert.equal(E.nodeFill('feature', feature({ progress: 0 })), 'zero')
  assert.equal(E.nodeFill('feature', feature({ progress: 1 })), 'full')
  assert.equal(E.nodeFill('task', task({ progress: 0 })), 'zero')
  assert.equal(E.nodeFill('task', task({ progress: 1 })), 'full')
  const none = feature({
    features: [
      feature({ id: 'a', progress: 0 }),
      feature({ id: 'b', progress: 0 }),
    ],
  })
  assert.equal(E.nodeFill('feature', none), 'zero')
  const part = feature({
    features: [
      feature({ id: 'a', progress: 1 }),
      feature({ id: 'b', progress: 0 }),
    ],
  })
  assert.equal(E.nodeFill('feature', part), 'part')
  const full = feature({
    features: [
      feature({ id: 'a', progress: 1 }),
      feature({ id: 'b', progress: 1 }),
    ],
  })
  assert.equal(E.nodeFill('feature', full), 'full')
})

test('isNodeOpen defaults open when has kids and closed when only processings', () => {
  assert.equal(E.isNodeOpen('a', true, false, {}), true)
  assert.equal(E.isNodeOpen('a', false, true, {}), false)
  assert.equal(E.isNodeOpen('a', true, true, {}), true)
  assert.equal(E.isNodeOpen('', true, false, {}), false)
  assert.equal(E.isNodeOpen('a', true, false, { a: true }), false)
  assert.equal(E.isNodeOpen('a', false, true, { a: false }), true)
})

test('foldableIds lists parents with kids or processings and skips leaves', () => {
  const root = feature({
    id: 'root',
    features: [
      feature({ id: 'leaf', progress: 0 }),
      feature({
        id: 'mid',
        features: [feature({ id: 'deep', progress: 0 })],
      }),
      feature({
        id: 'proc',
        progress: 0,
        tasks: [task({ id: 'T-1' })],
      }),
    ],
  })
  assert.deepEqual(E.foldableIds('feature', root), ['root', 'mid', 'proc'])
})

test('setAllCollapsed closes every foldable node so layout keeps only the root', () => {
  const root = feature({
    id: 'root',
    features: [
      feature({
        id: 'mid',
        features: [feature({ id: 'leaf', progress: 0 })],
      }),
    ],
  })
  const collapsed = E.setAllCollapsed('feature', root, true)
  assert.deepEqual(collapsed, { root: true, mid: true })
  assert.deepEqual(E.mapLayout('feature', root, { collapsed }).nodes.map((n) => n.id), ['root'])
})

test('setAllCollapsed opens processings that default closed', () => {
  const root = feature({
    id: 'root',
    tasks: [task({ id: 'T-1', title: '催' })],
  })
  assert.equal(E.isNodeOpen('root', false, true, {}), false)
  const open = E.setAllCollapsed('feature', root, false)
  assert.deepEqual(open, { root: false })
  assert.deepEqual(E.mapLayout('feature', root, { collapsed: open }).nodes.map((n) => n.id), ['root', 'T-1'])
})

test('mapLayout places a leaf at the origin', () => {
  const layout = E.mapLayout('feature', feature({ id: 'a', progress: 0 }), {
    nodeW: 180,
    nodeH: 56,
  })
  assert.equal(layout.width, 180)
  assert.equal(layout.height, 56)
  assert.equal(layout.nodes.length, 1)
  assert.equal(layout.nodes[0].id, 'a')
  assert.equal(layout.nodes[0].x, 0)
  assert.equal(layout.nodes[0].y, 0)
  assert.equal(layout.nodes[0].proc, false)
  assert.deepEqual(layout.edges, [])
})

test('mapLayout stacks open children to the right', () => {
  const root = feature({
    id: 'root',
    features: [
      feature({ id: 'a', progress: 0 }),
      feature({ id: 'b', progress: 1 }),
    ],
  })
  const layout = E.mapLayout('feature', root, {
    gapX: 56,
    gapY: 16,
    nodeW: 180,
    nodeH: 56,
  })
  const byId = {}
  layout.nodes.forEach((n) => { byId[n.id] = n })
  assert.equal(byId.a.x, 180 + 56)
  assert.equal(byId.b.x, 180 + 56)
  assert.equal(byId.b.y, byId.a.y + 56 + 16)
  assert.ok(byId.root.y > byId.a.y)
  assert.equal(layout.edges.length, 2)
})

test('mapLayout lists processings before features and marks dashed edges', () => {
  const root = feature({
    id: 'root',
    features: [feature({ id: 'kid', progress: 0 })],
    tasks: [task({ id: 'T-1', title: '催', progress: 0 })],
  })
  const layout = E.mapLayout('feature', root, {
    gapX: 56,
    gapY: 16,
    nodeW: 180,
    nodeH: 56,
    procW: 160,
    procH: 40,
  })
  const branch = layout.nodes.filter((n) => n.id !== 'root')
  assert.deepEqual(branch.map((n) => n.id), ['T-1', 'kid'])
  assert.equal(branch[0].proc, true)
  const edge = layout.edges.find((e) => e.toId === 'T-1')
  assert.equal(edge.dashed, true)
  const byId = {}
  layout.nodes.forEach((n) => { byId[n.id] = n })
  assert.equal(byId.root.procCount, 1)
})

test('mapLayout collapsed parent omits branches', () => {
  const root = feature({
    id: 'root',
    features: [feature({ id: 'kid', progress: 0 })],
  })
  const layout = E.mapLayout('feature', root, { collapsed: { root: true } })
  assert.deepEqual(layout.nodes.map((n) => n.id), ['root'])
  assert.deepEqual(layout.edges, [])
})

test('mapLinkPath is an orthogonal elbow', () => {
  const d = E.mapLinkPath(
    { x: 0, y: 0, w: 180, h: 56 },
    { x: 236, y: 72, w: 180, h: 56 },
  )
  assert.equal(d, 'M180 28 H208 V100 H236')
})

test('clampZoom panCam zoomCam keep the cursor world point', () => {
  assert.equal(E.clampZoom(0.2), 0.5)
  assert.equal(E.clampZoom(3), 1.5)
  assert.deepEqual(E.panCam({ x: 10, y: 20, z: 1 }, 5, -3), { x: 15, y: 17, z: 1 })
  const cam = E.zoomCam({ x: 0, y: 0, z: 1 }, 2, 100, 50)
  assert.equal(cam.z, 1.5)
  assert.equal((100 - cam.x) / cam.z, 100)
  assert.equal((50 - cam.y) / cam.z, 50)
})

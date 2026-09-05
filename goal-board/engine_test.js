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

test('summarize counts status and averages progress', () => {
  const s = E.summarize([
    goal({ status: 'on_track', progress: 80 }),
    goal({ status: 'on_track', progress: 60 }),
    goal({ status: 'completed', progress: 100 }),
    goal({ status: 'at_risk', progress: 40 }),
  ])
  assert.deepEqual(s, { total: 4, overall: 70, onTrack: 2, completed: 1, atRisk: 1 })
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

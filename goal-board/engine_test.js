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

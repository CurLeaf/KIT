'use strict'

const STATUS_RANK = { at_risk: 0, on_track: 1, completed: 2 }

const PHASE_MS = {
  OVERVIEW: 8000,
  GOALS: 15000,
  FOCUS: 8000,
  ACTIVITY: 8000,
}

function parseTime(iso) {
  const t = Date.parse(iso)
  return Number.isFinite(t) ? t : 0
}

function formatOperator(op) {
  if (op === '<=') return '≤'
  if (op === '>=') return '≥'
  if (op === '<' || op === '>' || op === '=') return op
  return ''
}

function formatMeasure(value, unit, operator) {
  const op = formatOperator(operator)
  const u = unit || ''
  const tight = u === 'ms' || u === '%'
  const body = tight ? `${value}${u}` : `${value}${u ? ` ${u}` : ''}`
  return op ? `${op} ${body}` : String(body)
}

function goalsByStage(goals, now = Date.now()) {
  const sorted = sortGoals(goals, now)
  const buckets = { discuss: [], develop: [], accept: [] }
  for (let i = 0; i < sorted.length; i += 1) {
    const g = sorted[i]
    if (g.status === 'completed') continue
    const key = g.stage && buckets[g.stage] ? g.stage : 'discuss'
    buckets[key].push(g)
  }
  return buckets
}

function sortGoals(goals, now = Date.now()) {
  void now
  return goals.slice().sort((a, b) => {
    const rank =
      (STATUS_RANK[a.status] != null ? STATUS_RANK[a.status] : 99) -
      (STATUS_RANK[b.status] != null ? STATUS_RANK[b.status] : 99)
    if (rank !== 0) return rank
    const dueA = parseTime(a.timeline && a.timeline.dueAt)
    const dueB = parseTime(b.timeline && b.timeline.dueAt)
    if (dueA !== dueB) {
      if (!dueA) return 1
      if (!dueB) return -1
      return dueA - dueB
    }
    const pa = a.progress == null ? 100 : a.progress
    const pb = b.progress == null ? 100 : b.progress
    if (pa !== pb) return pa - pb
    return parseTime(b.update && b.update.updatedAt) - parseTime(a.update && a.update.updatedAt)
  })
}

function scheduleVariance(goal, now) {
  const start = parseTime(goal.timeline && goal.timeline.startAt)
  const due = parseTime(goal.timeline && goal.timeline.dueAt)
  if (!start || !due || due <= start) return 0
  const expected = Math.min(100, Math.max(0, ((now - start) / (due - start)) * 100))
  return Math.max(0, expected - (goal.progress == null ? 0 : goal.progress))
}

function deadlineUrgency(goal, now) {
  const due = parseTime(goal.timeline && goal.timeline.dueAt)
  if (!due) return 0
  const days = (due - now) / 86400000
  if (days <= 0) return 40
  if (days <= 7) return 30
  if (days <= 14) return 20
  if (days <= 30) return 10
  return 0
}

function stalePenalty(goal, now) {
  const updated = parseTime(goal.update && goal.update.updatedAt)
  if (!updated) return 15
  const days = (now - updated) / 86400000
  if (days >= 14) return 20
  if (days >= 7) return 10
  return 0
}

function focusScore(goal, now = Date.now()) {
  let riskWeight = 0
  if (goal.status === 'at_risk') riskWeight = 100
  if (goal.status === 'completed') riskWeight = -50
  return riskWeight + scheduleVariance(goal, now) + deadlineUrgency(goal, now) + stalePenalty(goal, now)
}

function pickFocus(goals, limit = 3, now = Date.now()) {
  const n = Math.min(3, Math.max(0, limit))
  return goals.slice()
    .sort((a, b) => {
      const delta = focusScore(b, now) - focusScore(a, now)
      if (delta !== 0) return delta
      return sortGoals([a, b], now)[0] === a ? -1 : 1
    })
    .slice(0, n)
}

function visibleGoalCount(width) {
  if (width >= 3200) return 12
  if (width >= 2560) return 10
  if (width >= 1800) return 8
  return 6
}

function paginate(items, pageSize) {
  const size = Math.max(1, pageSize)
  if (!items.length) return [[]]
  const pages = []
  for (let i = 0; i < items.length; i += size) {
    pages.push(items.slice(i, i + size))
  }
  return pages
}

function summarize(goals) {
  const total = goals.length
  const onTrack = goals.filter((g) => g.status === 'on_track').length
  const completed = goals.filter((g) => g.status === 'completed').length
  const atRisk = goals.filter((g) => g.status === 'at_risk').length
  const overall = total
    ? Math.round(goals.reduce((sum, g) => sum + (g.progress == null ? 0 : g.progress), 0) / total)
    : 0
  return { total, overall, onTrack, completed, atRisk }
}

function formatTarget(target) {
  if (!target) return '—'
  const type = target.type || 'number'
  if (type === 'boolean') return target.value ? '✓' : '—'
  if (type === 'milestone') return target.label || String(target.value == null ? '—' : target.value)
  if (type === 'percentage') {
    const op = formatOperator(target.operator)
    return `${op}${op ? ' ' : ''}${target.value}%`
  }
  if (type === 'count') {
    const suffix = target.unit || target.label || ''
    return `${target.value}${suffix ? ` ${suffix}` : ''}`
  }
  const measure = formatMeasure(target.value, target.unit, target.operator)
  if (type === 'duration' && target.label) {
    const token = String(target.label).split(/\s+/)[0]
    return `${token} ${measure}`
  }
  return measure
}

function formatCurrent(current, target) {
  if (!current) return '—'
  const type = target && target.type
  if (type === 'boolean') return current.value ? '✓' : '—'
  if (type === 'milestone') {
    const total = target && target.value
    return total == null ? String(current.value) : `${current.value} / ${total}`
  }
  if (type === 'percentage') return `${current.value}%`
  const unit = current.unit || (target && target.unit) || ''
  return formatMeasure(current.value, unit)
}

function formatRelativeTime(iso, now = Date.now()) {
  const t = parseTime(iso)
  if (!t) return ''
  const sec = Math.max(0, Math.round((now - t) / 1000))
  if (sec < 60) return `${Math.max(1, sec)}s ago`
  const min = Math.round(sec / 60)
  if (min < 60) return `${min}m ago`
  const hours = Math.round(min / 60)
  if (hours < 48) return `${hours}h ago`
  return `${Math.round(hours / 24)}d ago`
}

function recentActivities(goals, limit = 8) {
  const rows = []
  for (const g of goals) {
    for (const a of g.activities || []) {
      rows.push({
        goalId: g.id,
        ownerName: (g.owner && g.owner.name) || '',
        text: a.text,
        at: a.at,
        type: a.type,
      })
    }
  }
  rows.sort((a, b) => parseTime(b.at) - parseTime(a.at))
  return rows.slice(0, limit)
}

function shouldReplace(prevMeta, nextMeta) {
  if (!prevMeta) return true
  return prevMeta.updatedAt !== (nextMeta && nextMeta.updatedAt)
}

function buildCycle(goalPageCount, focusCount) {
  const steps = [{ phase: 'OVERVIEW', index: 0 }]
  const pages = Math.max(1, goalPageCount)
  for (let i = 0; i < pages; i += 1) steps.push({ phase: 'GOALS', index: i })
  const focuses = Math.min(3, Math.max(1, focusCount))
  for (let i = 0; i < focuses; i += 1) steps.push({ phase: 'FOCUS', index: i })
  steps.push({ phase: 'ACTIVITY', index: 0 })
  return steps
}

function nextStepIndex(i, cycle) {
  return (i + 1) % cycle.length
}

function stepDuration(step) {
  return PHASE_MS[step.phase]
}

function phaseLabel(step, cycle) {
  const group = cycle.filter((s) => s.phase === step.phase)
  if (group.length <= 1) return step.phase
  const n = group.findIndex((s) => s.index === step.index) + 1
  return `${step.phase}  ·  ${n} / ${group.length}`
}

function advanceAutoScroll(top, max, carry, dt, speed) {
  if (max <= 0) return { top, carry: 0, wrapped: false }
  const nextCarry = carry + speed * (dt / 1000)
  const step = Math.floor(nextCarry)
  const remain = nextCarry - step
  if (step < 1) return { top, carry: remain, wrapped: false }
  const next = top + step
  if (next >= max) return { top: max, carry: 0, wrapped: true }
  return { top: next, carry: remain, wrapped: false }
}

function wrapLoopScroll(top, loopHeight) {
  if (loopHeight <= 0) return top
  return top % loopHeight
}

function resumeAutoTop(from, next, loopHeight, hitEnd) {
  if (loopHeight <= 0) return next
  if (hitEnd || (from < loopHeight && next >= loopHeight)) {
    return wrapLoopScroll(next, loopHeight)
  }
  return next
}

function sightRowIndex(scrollTop, rowHeight, count) {
  if (rowHeight <= 0 || count <= 0) return 0
  const i = Math.round(scrollTop / rowHeight)
  return ((i % count) + count) % count
}

function drumRowHeight(viewportHeight, slots = 3) {
  const n = Math.max(1, slots)
  return Math.floor(Math.max(0, viewportHeight) / n)
}

function drumPad(viewportHeight, rowHeight) {
  if (rowHeight <= 0) return 0
  return Math.max(0, Math.round((viewportHeight - rowHeight) / 2))
}

function drumCardHeight() {
  return 128
}

function pad2(n) {
  const s = String(n)
  return s.length >= 2 ? s : `0${s}`
}

function todayDataPath(now = new Date()) {
  const y = now.getFullYear()
  const m = pad2(now.getMonth() + 1)
  const d = pad2(now.getDate())
  return `data/${y}-${m}-${d}.json`
}

function snapTop(scrollTop, rowHeight) {
  if (rowHeight <= 0) return scrollTop
  return Math.round(scrollTop / rowHeight) * rowHeight
}

function ratchetEase(t) {
  const x = Math.max(0, Math.min(1, t))
  return x < 0.5
    ? 4 * x * x * x
    : 1 - Math.pow(-2 * x + 2, 3) / 2
}

function ratchetTop(fromSnap, rowHeight, elapsed, holdMs, moveMs, loopHeight) {
  if (rowHeight <= 0) return { top: fromSnap, done: true, wrapped: false }
  if (elapsed <= holdMs) return { top: fromSnap, done: false, wrapped: false }
  const span = Math.max(1, moveMs)
  const t = Math.min(1, (elapsed - holdMs) / span)
  const dest = fromSnap + rowHeight
  const top = fromSnap + (dest - fromSnap) * ratchetEase(t)
  if (t < 1) return { top, done: false, wrapped: false }
  if (loopHeight > 0 && dest >= loopHeight) {
    return { top: dest - loopHeight, done: true, wrapped: true }
  }
  return { top: dest, done: true, wrapped: false }
}

const GoalEngine = {
  sortGoals,
  goalsByStage,
  focusScore,
  pickFocus,
  visibleGoalCount,
  paginate,
  summarize,
  formatTarget,
  formatCurrent,
  formatRelativeTime,
  recentActivities,
  shouldReplace,
  PHASE_MS,
  buildCycle,
  nextStepIndex,
  stepDuration,
  phaseLabel,
  advanceAutoScroll,
  wrapLoopScroll,
  resumeAutoTop,
  sightRowIndex,
  drumRowHeight,
  drumPad,
  drumCardHeight,
  todayDataPath,
  snapTop,
  ratchetEase,
  ratchetTop,
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = GoalEngine
}
if (typeof window !== 'undefined') {
  window.GoalEngine = GoalEngine
}

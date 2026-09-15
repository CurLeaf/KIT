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

function treeChildren(parent) {
  const rows = []
  if (!parent) return rows
  const features = parent.features || []
  for (let i = 0; i < features.length; i += 1) {
    rows.push({ kind: 'feature', item: features[i] })
  }
  return rows
}

function nodeProcessings(parent) {
  if (!parent) return []
  return (parent.tasks || []).slice()
}

function previewNode(kind, item, depth, maxDepth, maxChildren) {
  const all = kind === 'task' || !item ? [] : treeChildren(item)
  const node = {
    kind,
    id: item && item.id,
    title: (item && item.title) || '',
    ownerName: (item && item.owner && item.owner.name) || '',
    progress: nodeProgress(kind, item),
    leafCount: nodeLeafCount(kind, item),
    leaf: all.length === 0,
    children: [],
    omitted: 0,
  }
  if (kind === 'task' || !item) return node
  if (depth >= maxDepth) {
    node.omitted = all.length
    return node
  }
  const extra = Math.max(0, all.length - maxChildren)
  const take = all.slice(0, maxChildren)
  node.omitted = extra
  for (let i = 0; i < take.length; i += 1) {
    node.children.push(previewNode(take[i].kind, take[i].item, depth + 1, maxDepth, maxChildren))
  }
  return node
}

function previewTree(project, options) {
  const maxDepth = options && options.maxDepth != null ? options.maxDepth : 2
  const maxChildren = options && options.maxChildren != null ? options.maxChildren : 4
  if (!project) {
    return {
      kind: 'project',
      id: undefined,
      title: '',
      ownerName: '',
      progress: 0,
      leafCount: 0,
      leaf: true,
      children: [],
      omitted: 0,
    }
  }
  return previewNode('project', project, 0, maxDepth, maxChildren)
}

function readProjects(data) {
  if (!data || data.schemaVersion !== '1.1' || !Array.isArray(data.projects)) {
    throw new Error('unsupported schema')
  }
  return data.projects
}

function isLeafNode(kind, item) {
  if (!item) return true
  if (kind === 'task') return true
  return treeChildren(item).length === 0
}

function nodeProgress(kind, item) {
  if (!item) return 0
  if (isLeafNode(kind, item)) return item.progress === 1 ? 1 : 0
  const kids = treeChildren(item)
  let sum = 0
  for (let i = 0; i < kids.length; i += 1) {
    sum += nodeProgress(kids[i].kind, kids[i].item)
  }
  return sum
}

function nodeLeafCount(kind, item) {
  if (!item) return 0
  if (isLeafNode(kind, item)) return 1
  const kids = treeChildren(item)
  let n = 0
  for (let i = 0; i < kids.length; i += 1) {
    n += nodeLeafCount(kids[i].kind, kids[i].item)
  }
  return n
}

function nodeCount(kind, item) {
  if (!item || kind === 'task') return 0
  const kids = treeChildren(item)
  let n = kind === 'project' ? 0 : 1
  for (let i = 0; i < kids.length; i += 1) {
    n += nodeCount(kids[i].kind, kids[i].item)
  }
  return n
}

function nodeFill(kind, item) {
  if (!item) return 'zero'
  const done = nodeProgress(kind, item)
  if (isLeafNode(kind, item)) return done === 1 ? 'full' : 'zero'
  const leaves = nodeLeafCount(kind, item)
  if (!leaves || done <= 0) return 'zero'
  if (done >= leaves) return 'full'
  return 'part'
}

function isNodeOpen(id, hasKids, hasProc, collapsed) {
  if (!id || (!hasKids && !hasProc)) return false
  if (collapsed && Object.prototype.hasOwnProperty.call(collapsed, id)) {
    return !collapsed[id]
  }
  return !!hasKids
}

function foldableIds(kind, item, acc) {
  const out = acc || []
  if (!item || kind === 'task') return out
  const kids = treeChildren(item)
  const procs = nodeProcessings(item)
  const id = item.id != null ? String(item.id) : ''
  if (id && (kids.length > 0 || procs.length > 0)) out.push(id)
  for (let i = 0; i < kids.length; i += 1) {
    foldableIds(kids[i].kind, kids[i].item, out)
  }
  return out
}

function setAllCollapsed(kind, item, closed) {
  const ids = foldableIds(kind, item)
  const next = {}
  for (let i = 0; i < ids.length; i += 1) next[ids[i]] = !!closed
  return next
}

function mapLayout(kind, item, options) {
  const opts = options || {}
  const gapX = opts.gapX != null ? opts.gapX : 56
  const gapY = opts.gapY != null ? opts.gapY : 16
  const nodeW = opts.nodeW != null ? opts.nodeW : 180
  const nodeH = opts.nodeH != null ? opts.nodeH : 56
  const procW = opts.procW != null ? opts.procW : 160
  const procH = opts.procH != null ? opts.procH : 40
  const collapsed = opts.collapsed || {}
  if (!item) return { nodes: [], edges: [], width: 0, height: 0 }

  function sizeOf(k) {
    if (k === 'task') return { w: procW, h: procH }
    return { w: nodeW, h: nodeH }
  }

  function measure(k, row) {
    const box = sizeOf(k)
    const kids = k === 'task' ? [] : treeChildren(row)
    const procs = k === 'task' ? [] : nodeProcessings(row)
    const id = row && row.id != null ? String(row.id) : ''
    const open = isNodeOpen(id, kids.length > 0, procs.length > 0, collapsed)
    const branches = []
    if (open) {
      for (let i = 0; i < procs.length; i += 1) {
        branches.push({ kind: 'task', item: procs[i], sub: measure('task', procs[i]) })
      }
      for (let i = 0; i < kids.length; i += 1) {
        branches.push({
          kind: kids[i].kind,
          item: kids[i].item,
          sub: measure(kids[i].kind, kids[i].item),
        })
      }
    }
    if (!branches.length) {
      return { w: box.w, h: box.h, nw: box.w, nh: box.h, open, branches, id, kind: k }
    }
    let colH = 0
    let colW = 0
    for (let i = 0; i < branches.length; i += 1) {
      if (i) colH += gapY
      colH += branches[i].sub.h
      if (branches[i].sub.w > colW) colW = branches[i].sub.w
    }
    return {
      w: box.w + gapX + colW,
      h: Math.max(box.h, colH),
      nw: box.w,
      nh: box.h,
      open,
      branches,
      id,
      kind: k,
      colH,
    }
  }

  const nodes = []
  const edges = []

  function stamp(k, row, x, y) {
    const leaf = k === 'task' ? true : isLeafNode(k, row)
    const procs = k === 'task' ? [] : nodeProcessings(row)
    return {
      id: row && row.id != null ? String(row.id) : '',
      kind: k,
      title: (row && row.title) || '',
      ownerName: (row && row.owner && row.owner.name) || '',
      x,
      y,
      w: k === 'task' ? procW : nodeW,
      h: k === 'task' ? procH : nodeH,
      fill: nodeFill(k, row),
      progress: nodeProgress(k, row),
      leafCount: nodeLeafCount(k, row),
      leaf,
      hasKids: k !== 'task' && treeChildren(row).length > 0,
      hasProc: procs.length > 0,
      procCount: procs.length,
      open: false,
      proc: k === 'task',
    }
  }

  function place(k, row, tree, x, y) {
    const boxY = y + (tree.h - tree.nh) / 2
    const node = stamp(k, row, x, boxY)
    node.open = tree.open
    nodes.push(node)
    if (!tree.branches.length) return
    let cy = y + (tree.h - tree.colH) / 2
    const cx = x + tree.nw + gapX
    for (let i = 0; i < tree.branches.length; i += 1) {
      const b = tree.branches[i]
      const childId = b.item && b.item.id != null ? String(b.item.id) : ''
      edges.push({ fromId: node.id, toId: childId, dashed: b.kind === 'task' })
      place(b.kind, b.item, b.sub, cx, cy)
      cy += b.sub.h + gapY
    }
  }

  const tree = measure(kind, item)
  place(kind, item, tree, 0, 0)
  return { nodes, edges, width: tree.w, height: tree.h }
}

function mapLinkPath(from, to) {
  if (!from || !to) return ''
  const x1 = from.x + from.w
  const y1 = from.y + from.h / 2
  const x2 = to.x
  const y2 = to.y + to.h / 2
  const mx = (x1 + x2) / 2
  return `M${x1} ${y1} H${mx} V${y2} H${x2}`
}

function clampZoom(z) {
  const n = Number(z)
  if (!Number.isFinite(n)) return 1
  if (n < 0.5) return 0.5
  if (n > 1.5) return 1.5
  return n
}

function panCam(cam, dx, dy) {
  const z = clampZoom(cam && cam.z)
  return {
    x: ((cam && cam.x) || 0) + (Number(dx) || 0),
    y: ((cam && cam.y) || 0) + (Number(dy) || 0),
    z,
  }
}

function zoomCam(cam, factor, px, py) {
  const x = (cam && cam.x) || 0
  const y = (cam && cam.y) || 0
  const z = clampZoom(cam && cam.z)
  const z2 = clampZoom(z * (Number(factor) || 1))
  if (!z) return { x, y, z: z2 }
  const cx = Number(px) || 0
  const cy = Number(py) || 0
  return {
    x: cx - ((cx - x) * z2) / z,
    y: cy - ((cy - y) * z2) / z,
    z: z2,
  }
}

function descendantTasks(feature) {
  if (!feature) return []
  const rows = []
  const tasks = feature.tasks || []
  for (let i = 0; i < tasks.length; i += 1) rows.push(tasks[i])
  const children = feature.features || []
  for (let i = 0; i < children.length; i += 1) {
    const nested = descendantTasks(children[i])
    for (let j = 0; j < nested.length; j += 1) rows.push(nested[j])
  }
  return rows
}

function collectFeatureTasks(features, ctx) {
  const rows = []
  const list = features || []
  for (let i = 0; i < list.length; i += 1) {
    const f = list[i]
    const tasks = f.tasks || []
    for (let j = 0; j < tasks.length; j += 1) {
      rows.push({
        ...tasks[j],
        projectId: ctx.projectId,
        projectTitle: ctx.projectTitle,
        featureId: f.id,
        featureTitle: f.title,
        featureOwner: f.owner || null,
      })
    }
    const nested = collectFeatureTasks(f.features, ctx)
    for (let k = 0; k < nested.length; k += 1) rows.push(nested[k])
  }
  return rows
}

function flattenTasks(projects) {
  const rows = []
  const list = projects || []
  for (let i = 0; i < list.length; i += 1) {
    const p = list[i]
    const nested = collectFeatureTasks(p.features, {
      projectId: p.id,
      projectTitle: p.title,
    })
    for (let j = 0; j < nested.length; j += 1) rows.push(nested[j])
  }
  return rows
}

function rollupProgress(tasks) {
  const list = tasks || []
  if (!list.length) return 0
  let sum = 0
  for (let i = 0; i < list.length; i += 1) {
    const p = list[i].progress
    sum += p == null ? 0 : p
  }
  return Math.round(sum / list.length)
}

function rollupStatus(tasks) {
  const list = tasks || []
  if (!list.length) return 'on_track'
  let allCompleted = true
  for (let i = 0; i < list.length; i += 1) {
    if (list[i].status === 'at_risk') return 'at_risk'
    if (list[i].status !== 'completed') allCompleted = false
  }
  return allCompleted ? 'completed' : 'on_track'
}

function summarize(projects) {
  const list = projects || []
  const tasks = flattenTasks(list)
  const total = tasks.length
  const onTrack = tasks.filter((g) => g.status === 'on_track').length
  const completed = tasks.filter((g) => g.status === 'completed').length
  const atRisk = tasks.filter((g) => g.status === 'at_risk').length
  return {
    projects: list.length,
    tasks: total,
    total,
    overall: rollupProgress(tasks),
    onTrack,
    completed,
    atRisk,
  }
}

function compareRollup(tasksA, tasksB) {
  const rankA = STATUS_RANK[rollupStatus(tasksA)] != null ? STATUS_RANK[rollupStatus(tasksA)] : 99
  const rankB = STATUS_RANK[rollupStatus(tasksB)] != null ? STATUS_RANK[rollupStatus(tasksB)] : 99
  if (rankA !== rankB) return rankA - rankB
  return rollupProgress(tasksA) - rollupProgress(tasksB)
}

function sortProjects(projects) {
  return (projects || []).slice().sort((a, b) => (
    compareRollup(flattenTasks([a]), flattenTasks([b]))
  ))
}

function sortFeatures(features) {
  return (features || []).slice().sort((a, b) => (
    compareRollup(descendantTasks(a), descendantTasks(b))
  ))
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
  readProjects,
  treeChildren,
  nodeProcessings,
  previewTree,
  nodeProgress,
  nodeLeafCount,
  nodeCount,
  nodeFill,
  isNodeOpen,
  foldableIds,
  setAllCollapsed,
  mapLayout,
  mapLinkPath,
  clampZoom,
  panCam,
  zoomCam,
  flattenTasks,
  descendantTasks,
  rollupProgress,
  rollupStatus,
  sortProjects,
  sortFeatures,
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

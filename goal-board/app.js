'use strict'

;(function () {
  const E = window.GoalEngine
  const DATA_URL = 'data/goals.json'
  const REFRESH_MS = 5 * 60 * 1000
  const SCROLL_PX_PER_SEC = 28
  const END_HOLD_MS = 2000
  const INTERACT_PAUSE_MS = 8000

  const els = {
    sub: document.getElementById('board-sub'),
    period: document.getElementById('clock-period'),
    week: document.getElementById('clock-week'),
    time: document.getElementById('clock-time'),
    summary: document.getElementById('summary'),
    list: document.getElementById('goal-list'),
    activity: document.getElementById('activity-list'),
    scroller: document.getElementById('board-scroll'),
  }

  const state = {
    meta: null,
    goals: [],
    sorted: [],
    pausedUntil: 0,
    endHoldUntil: 0,
    lastTs: 0,
  }

  function pad(n) {
    return String(n).padStart(2, '0')
  }

  function tickClock() {
    const d = new Date()
    els.time.textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  }

  function statusLabel(status) {
    if (status === 'at_risk') return 'AT RISK'
    if (status === 'completed') return 'COMPLETED'
    return 'ON TRACK'
  }

  function summaryItem(value, label) {
    return `<div class="summary-item"><div class="summary-value">${value}</div><div class="summary-label">${label}</div></div>`
  }

  function progressRow(pct) {
    const width = Math.max(0, Math.min(100, pct || 0))
    return `<div class="goal-progress"><span class="progress-value">${width}%</span><div class="progress-track"><span class="progress-fill" style="width:${width}%"></span></div></div>`
  }

  function ownerLine(owner) {
    const name = (owner && owner.name) || '—'
    const role = (owner && owner.role) || ''
    return `<span class="owner"><span class="owner-dot"></span>${name}${role ? ` · ${role}` : ''}</span>`
  }

  function renderGoalRow(goal) {
    const risk = goal.status === 'at_risk'
    const note = risk && goal.update && goal.update.text
      ? `<p class="goal-update">${goal.update.text}</p>`
      : ''
    return `<article class="goal${risk ? ' is-risk' : ''}">
      <div class="goal-id">${goal.id}</div>
      <div class="goal-copy">
        <h3 class="goal-title">${goal.title}</h3>
        ${note}
      </div>
      ${progressRow(goal.progress)}
      <div class="goal-result">
        <span class="result-target">${E.formatTarget(goal.target)}</span>
        <span class="result-sep">→</span>
        <span class="result-current">${E.formatCurrent(goal.current, goal.target)}</span>
      </div>
      ${ownerLine(goal.owner)}
      <span class="status status-${goal.status}">${statusLabel(goal.status)}</span>
    </article>`
  }

  function render() {
    els.list.innerHTML = state.sorted.map(renderGoalRow).join('')
    const now = Date.now()
    els.activity.innerHTML = E.recentActivities(state.sorted, 8).map((row) => `
      <div class="activity">
        <span class="activity-goal">${row.goalId}</span>
        <span class="activity-owner">${row.ownerName}</span>
        <span class="activity-text">${row.text}</span>
        <span class="activity-time">${E.formatRelativeTime(row.at, now)}</span>
      </div>`).join('')
  }

  function hydrate(data) {
    const goals = Array.isArray(data.goals) ? data.goals : []
    state.meta = data.meta || {}
    state.goals = goals
    state.sorted = E.sortGoals(goals)
    els.sub.textContent = state.meta.title || 'Engineering Goal Board'
    els.period.textContent = state.meta.period || ''
    els.week.textContent = state.meta.week != null ? `Week ${state.meta.week}` : ''
    const sum = E.summarize(state.sorted)
    els.summary.innerHTML = [
      summaryItem(sum.total, 'GOALS'),
      summaryItem(`${sum.overall}%`, 'OVERALL'),
      summaryItem(sum.onTrack, 'ON TRACK'),
      summaryItem(sum.completed, 'COMPLETED'),
      summaryItem(sum.atRisk, 'AT RISK'),
    ].join('')
    render()
    if (els.scroller) els.scroller.scrollTop = 0
    state.endHoldUntil = 0
  }

  async function load({ force }) {
    const res = await fetch(DATA_URL, { cache: 'no-store' })
    if (!res.ok) throw new Error(`goals.json ${res.status}`)
    const data = await res.json()
    if (!force && !E.shouldReplace(state.meta, data.meta)) return
    hydrate(data)
  }

  function prefersReducedMotion() {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  function pauseAuto() {
    state.pausedUntil = performance.now() + INTERACT_PAUSE_MS
  }

  function tickScroll() {
    const ts = performance.now()
    if (!state.lastTs) state.lastTs = ts
    const dt = Math.min(64, ts - state.lastTs)
    state.lastTs = ts
    const scroller = els.scroller
    if (scroller && !prefersReducedMotion()) {
      const max = scroller.scrollHeight - scroller.clientHeight
      if (max > 0 && ts >= state.pausedUntil) {
        if (state.endHoldUntil && ts >= state.endHoldUntil) {
          scroller.scrollTop = 0
          state.endHoldUntil = 0
        } else if (!state.endHoldUntil) {
          const next = scroller.scrollTop + SCROLL_PX_PER_SEC * (dt / 1000)
          if (next >= max) {
            scroller.scrollTop = max
            state.endHoldUntil = ts + END_HOLD_MS
          } else {
            scroller.scrollTop = next
          }
        }
      }
    }
    window.requestAnimationFrame(tickScroll)
  }

  tickClock()
  window.setInterval(tickClock, 1000)
  window.setInterval(() => {
    load({ force: false }).catch((err) => console.warn(err))
  }, REFRESH_MS)
  if (els.scroller) {
    els.scroller.addEventListener('pointerenter', pauseAuto)
    els.scroller.addEventListener('wheel', pauseAuto, { passive: true })
  }
  window.requestAnimationFrame(tickScroll)
  load({ force: true }).catch((err) => {
    els.sub.textContent = 'Failed to load goals.json'
    console.warn(err)
  })
})()

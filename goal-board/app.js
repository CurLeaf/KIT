'use strict'

;(function () {
  if (typeof NodeList !== 'undefined' && NodeList.prototype && !NodeList.prototype.forEach) {
    NodeList.prototype.forEach = Array.prototype.forEach
  }
  const E = window.GoalEngine
  const REFRESH_MS = 5 * 60 * 1000
  const RATCHET_HOLD_MS = 2400
  const RATCHET_MOVE_MS = 780

  const STAGE_KEYS = [
    { key: 'discuss', label: '讨论' },
    { key: 'develop', label: '开发' },
    { key: 'accept', label: '验收' },
  ]
  const STAGE_RANK = { discuss: 0, develop: 1, accept: 2 }

  const els = {
    title: document.getElementById('board-title'),
    period: document.getElementById('clock-period'),
    week: document.getElementById('clock-week'),
    time: document.getElementById('clock-time'),
    summary: document.getElementById('summary'),
    list: document.getElementById('goal-list'),
    drum: document.getElementById('board-drum'),
    scroller: document.getElementById('board-scroll'),
    loop: document.getElementById('board-loop'),
    inner: document.getElementById('board-scroll-inner'),
  }

  const state = {
    meta: null,
    goals: [],
    sorted: [],
    lastTs: 0,
    loopHeight: 0,
    rowHeight: 0,
    fromSnap: 0,
    ratchetAt: 0,
  }

  function pad(n) {
    return String(n).padStart(2, '0')
  }

  function tickClock() {
    const d = new Date()
    els.time.textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}`
  }

  function summaryItem(value, label) {
    return `<div class="summary-item"><div class="summary-value">${value}</div><div class="summary-label">${label}</div></div>`
  }

  function renderStages(goal) {
    const current = goal.stage || 'discuss'
    const currentRank = STAGE_RANK[current] != null ? STAGE_RANK[current] : 0
    return `<div class="goal-stages">${STAGE_KEYS.map((s) => {
      const owner = goal.stages && goal.stages[s.key] && goal.stages[s.key].owner
      const name = (owner && owner.name) || ''
      const rank = STAGE_RANK[s.key]
      const cls = currentRank > rank ? ' is-done' : current === s.key ? ' is-current' : ''
      return `<div class="stage${cls}">
        <span class="stage-dot"></span>
        <span class="stage-label">${s.label}</span>
        <span class="stage-owner">${name}</span>
      </div>`
    }).join('')}</div>`
  }

  function circledNo(index) {
    const n = index + 1
    if (n >= 1 && n <= 20) return String.fromCharCode(0x245F + n)
    return String(n)
  }

  function renderGoalRow(goal, index) {
    const risk = goal.status === 'at_risk'
    const note = goal.update && goal.update.text
      ? `<p class="goal-update">${goal.update.text}</p>`
      : ''
    return `<article class="goal${risk ? ' is-risk' : ''}" data-index="${index}">
      <span class="goal-no">${circledNo(index)}</span>
      <div class="goal-copy">
        <h3 class="goal-title">${goal.title}</h3>
        ${note}
      </div>
      ${renderStages(goal)}
    </article>`
  }

  function render() {
    els.list.innerHTML = state.sorted.map(renderGoalRow).join('')
    layoutDrum()
    syncLoopClone()
    markCurrent()
  }

  function layoutDrum() {
    if (!els.scroller || !els.drum || !els.loop) return
    const viewport = els.drum.clientHeight
    if (viewport < 1) return
    const row = E.drumCardHeight()
    const inset = E.drumPad(viewport, row)
    state.rowHeight = row
    state.loopHeight = state.sorted.length * row
    els.drum.style.setProperty('--drum-row', `${row}px`)
    els.loop.style.paddingTop = `${inset}px`
    els.loop.style.paddingBottom = `${inset}px`
  }

  function syncLoopClone() {
    if (!els.loop || !els.inner) return
    const old = els.loop.querySelector('[data-loop-clone]')
    if (old) old.remove()
    const clone = els.inner.cloneNode(true)
    clone.removeAttribute('id')
    clone.querySelectorAll('[id]').forEach((node) => node.removeAttribute('id'))
    clone.setAttribute('data-loop-clone', '1')
    clone.setAttribute('aria-hidden', 'true')
    els.loop.appendChild(clone)
  }

  function markCurrent() {
    if (!els.loop || !els.drum || !state.sorted.length) return
    const idx = E.sightRowIndex(state.fromSnap, state.rowHeight, state.sorted.length)
    const band = els.drum.querySelector('.sight-band')
    const bandBox = band && band.getBoundingClientRect()
    const bandMid = bandBox ? bandBox.top + bandBox.height / 2 : 0
    let nearest = null
    let nearestDist = Infinity
    const cards = els.loop.querySelectorAll('.goal')
    cards.forEach((node) => {
      if (Number(node.getAttribute('data-index')) !== idx) return
      const box = node.getBoundingClientRect()
      const dist = Math.abs(box.top + box.height / 2 - bandMid)
      if (dist < nearestDist) {
        nearestDist = dist
        nearest = node
      }
    })
    cards.forEach((node) => {
      if (node === nearest) node.classList.add('is-current')
      else node.classList.remove('is-current')
    })
  }

  function hydrate(data) {
    const goals = Array.isArray(data.goals) ? data.goals : []
    state.meta = data.meta || {}
    state.goals = goals
    state.sorted = E.sortGoals(goals)
    els.period.textContent = state.meta.period || ''
    els.week.textContent = state.meta.week != null ? `第 ${state.meta.week} 周` : ''
    const sum = E.summarize(state.sorted)
    els.summary.innerHTML = [
      summaryItem(sum.total, '目标'),
      summaryItem(`${sum.overall}%`, '整体'),
      summaryItem(sum.onTrack, '正常'),
      summaryItem(sum.completed, '已完成'),
      summaryItem(sum.atRisk, '风险'),
    ].join('')
    render()
    if (els.scroller) els.scroller.scrollTop = 0
    state.fromSnap = 0
    state.ratchetAt = 0
    markCurrent()
  }

  async function load({ force }) {
    const url = E.todayDataPath()
    const res = await fetch(url, { cache: 'no-store' })
    if (!res.ok) throw new Error(`${url} ${res.status}`)
    const data = await res.json()
    if (!force && !E.shouldReplace(state.meta, data.meta)) return
    hydrate(data)
  }

  function prefersReducedMotion() {
    return window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches
  }

  function tickScroll() {
    const ts = performance.now()
    state.lastTs = ts
    const scroller = els.scroller
    if (scroller && state.rowHeight > 0 && !prefersReducedMotion()) {
      if (!state.ratchetAt) {
        state.ratchetAt = ts
        state.fromSnap = E.snapTop(scroller.scrollTop, state.rowHeight)
      }
      const step = E.ratchetTop(
        state.fromSnap,
        state.rowHeight,
        ts - state.ratchetAt,
        RATCHET_HOLD_MS,
        RATCHET_MOVE_MS,
        state.loopHeight,
      )
      scroller.scrollTop = step.top
      if (step.done) {
        state.fromSnap = step.top
        state.ratchetAt = ts
      }
      markCurrent()
    }
    window.requestAnimationFrame(tickScroll)
  }

  function stepBy(dir) {
    if (!els.scroller || !state.rowHeight) return
    let next = state.fromSnap + dir * state.rowHeight
    if (state.loopHeight > 0) {
      if (next < 0) next = state.loopHeight - state.rowHeight
      if (next >= state.loopHeight) next = 0
    }
    state.fromSnap = next
    state.ratchetAt = performance.now()
    els.scroller.scrollTop = next
    markCurrent()
  }

  tickClock()
  window.setInterval(tickClock, 1000)
  window.setInterval(() => {
    load({ force: false }).catch((err) => console.warn(err))
  }, REFRESH_MS)
  function onDrumResize() {
    if (!state.sorted.length) return
    const idx = E.sightRowIndex(state.fromSnap, state.rowHeight, state.sorted.length)
    layoutDrum()
    syncLoopClone()
    state.fromSnap = idx * state.rowHeight
    state.ratchetAt = 0
    els.scroller.scrollTop = state.fromSnap
    markCurrent()
  }
  if (els.drum && typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(onDrumResize).observe(els.drum)
  } else {
    window.addEventListener('resize', onDrumResize)
  }
  if (els.scroller) {
    els.scroller.addEventListener('wheel', (event) => {
      event.preventDefault()
      stepBy(event.deltaY > 0 ? 1 : -1)
    }, { passive: false })
  }
  window.requestAnimationFrame(tickScroll)
  load({ force: true }).catch((err) => {
    if (els.title) els.title.textContent = '无法加载目标数据'
    console.warn(err)
  })
})()

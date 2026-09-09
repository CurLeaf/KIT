'use strict'

;(function () {
  if (typeof NodeList !== 'undefined' && NodeList.prototype && !NodeList.prototype.forEach) {
    NodeList.prototype.forEach = Array.prototype.forEach
  }
  const E = window.GoalEngine
  const REFRESH_MS = 5 * 60 * 1000
  const STAGE_KEYS = [
    { key: 'discuss', label: '讨论' },
    { key: 'develop', label: '开发' },
    { key: 'accept', label: '验收' },
  ]
  const els = {
    title: document.getElementById('board-title'),
    period: document.getElementById('clock-period'),
    week: document.getElementById('clock-week'),
    time: document.getElementById('clock-time'),
    summary: document.getElementById('summary'),
    kanban: document.getElementById('kanban'),
  }

  const state = {
    meta: null,
    goals: [],
  }

  function pad2(n) {
    const s = String(n)
    return s.length >= 2 ? s : `0${s}`
  }

  function tickClock() {
    const d = new Date()
    if (els.time) els.time.textContent = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`
  }

  function esc(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
  }

  function summaryItem(value, label) {
    return `<div class="summary-item"><div class="summary-value">${value}</div><div class="summary-label">${label}</div></div>`
  }

  function noteOwner(goal) {
    const stage = goal.stage
    const staged = goal.stages && stage && goal.stages[stage] && goal.stages[stage].owner
    if (staged && staged.name) return staged.name
    return (goal.owner && goal.owner.name) || ''
  }

  function renderNote(goal) {
    const risk = goal.status === 'at_risk' ? ' is-risk' : ''
    const owner = noteOwner(goal)
    const update = goal.update && goal.update.text ? goal.update.text : ''
    return `<article class="note${risk}">
      <h3 class="note-title">${esc(goal.title)}</h3>
      <p class="note-owner">${esc(owner)}</p>
      <p class="note-update">${esc(update)}</p>
    </article>`
  }

  function renderColumns(columns) {
    for (let i = 0; i < STAGE_KEYS.length; i += 1) {
      const key = STAGE_KEYS[i].key
      const list = (columns && columns[key]) || []
      const count = document.getElementById(`count-${key}`)
      const box = document.getElementById(`col-${key}`)
      if (count) count.textContent = String(list.length)
      if (box) {
        box.innerHTML = list.length
          ? list.map(renderNote).join('')
          : '<p class="column-empty">暂无目标</p>'
      }
    }
  }

  function hydrate(data) {
    const goals = Array.isArray(data.goals) ? data.goals : []
    state.meta = data.meta || {}
    state.goals = goals
    if (els.title && state.meta.title) els.title.textContent = state.meta.title
    if (els.period) els.period.textContent = state.meta.period || ''
    if (els.week) els.week.textContent = state.meta.week != null ? `第 ${state.meta.week} 周` : ''
    const sum = E.summarize(goals)
    if (els.summary) {
      els.summary.innerHTML = [
        summaryItem(sum.total, '目标'),
        summaryItem(`${sum.overall}%`, '整体'),
        summaryItem(sum.onTrack, '正常'),
        summaryItem(sum.completed, '已完成'),
        summaryItem(sum.atRisk, '风险'),
      ].join('')
    }
    renderColumns(E.goalsByStage(goals))
  }

  function getJson(url, done, fail) {
    if (typeof fetch === 'function') {
      fetch(url).then(function (res) {
        if (!res.ok) throw new Error(`${url} ${res.status}`)
        return res.json()
      }).then(done, fail)
      return
    }
    const xhr = new XMLHttpRequest()
    xhr.open('GET', url, true)
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return
      if (xhr.status < 200 || xhr.status >= 300) {
        fail(new Error(`${url} ${xhr.status}`))
        return
      }
      try {
        done(JSON.parse(xhr.responseText))
      } catch (err) {
        fail(err)
      }
    }
    xhr.send(null)
  }

  function load(opts) {
    const force = opts && opts.force
    const url = `${E.todayDataPath()}?t=${Date.now()}`
    getJson(url, function (data) {
      if (!force && !E.shouldReplace(state.meta, data.meta)) return
      hydrate(data)
    }, function (err) {
      if (els.title) els.title.textContent = '无法加载目标数据'
      console.warn(err)
    })
  }

  tickClock()
  window.setInterval(tickClock, 1000)
  window.setInterval(function () {
    load({ force: false })
  }, REFRESH_MS)
  load({ force: true })
})()

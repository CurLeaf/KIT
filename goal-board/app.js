'use strict'

;(function () {
  if (typeof NodeList !== 'undefined' && NodeList.prototype && !NodeList.prototype.forEach) {
    NodeList.prototype.forEach = Array.prototype.forEach
  }
  const E = window.GoalEngine
  const REFRESH_MS = 5 * 60 * 1000
  const CAM0 = { x: 48, y: 40, z: 1 }
  const els = {
    title: document.getElementById('board-title'),
    period: document.getElementById('clock-period'),
    week: document.getElementById('clock-week'),
    time: document.getElementById('clock-time'),
    summary: document.getElementById('summary'),
    explorer: document.getElementById('explorer'),
  }

  const state = {
    meta: null,
    projects: [],
    view: 'files',
    openProjectId: null,
    collapsed: {},
    cam: { x: CAM0.x, y: CAM0.y, z: CAM0.z },
    drag: { on: false, x: 0, y: 0, moved: false },
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

  function failLoad(err) {
    if (els.title) els.title.textContent = '无法加载目标数据'
    console.warn(err)
  }

  function findProject(id) {
    const list = state.projects || []
    for (let i = 0; i < list.length; i += 1) {
      if (list[i].id === id) return list[i]
    }
    return null
  }

  function classOf(node) {
    if (!node || !node.getAttribute) return ''
    return String(node.getAttribute('class') || '')
  }

  function resetCam() {
    state.cam = { x: CAM0.x, y: CAM0.y, z: CAM0.z }
  }

  function applyCam() {
    const world = els.explorer && els.explorer.querySelector('.tree-world')
    if (!world) return
    const cam = state.cam
    world.style.transform = `translate(${cam.x}px, ${cam.y}px) scale(${cam.z})`
  }

  function toggleNode(id, hasKids, hasProc) {
    if (!id || (!hasKids && !hasProc)) return
    state.collapsed[id] = E.isNodeOpen(id, hasKids, hasProc, state.collapsed)
  }

  function treeRoot(project) {
    const kids = E.treeChildren(project)
    if (!kids.length) return null
    return kids.length === 1 ? kids[0] : { kind: 'project', item: project }
  }

  function applyAllFold(closed) {
    const project = findProject(state.openProjectId)
    if (!project) return
    const root = treeRoot(project)
    if (!root) return
    state.collapsed = E.setAllCollapsed(root.kind, root.item, closed)
    resetCam()
    renderBoard()
  }

  function renderMiniNode(node) {
    const kids = (node && node.children) || []
    const leaf = !!(node && node.leaf)
    const done = node && node.progress != null ? node.progress : 0
    const leaves = node && node.leafCount != null ? node.leafCount : 0
    const score = leaf ? String(done) : `${done}/${leaves}`
    const omitted = node && node.omitted ? `<div class="mini-more">+${esc(node.omitted)}</div>` : ''
    const childHtml = kids.map((c) => `<div class="mini-kid">${renderMiniNode(c)}</div>`).join('')
    const kidsWrap = (kids.length || (node && node.omitted))
      ? `<div class="mini-kids">${childHtml}${omitted}</div>`
      : ''
    const on = (leaf && done === 1) || (!leaf && leaves && done >= leaves) ? ' is-on' : ''
    const part = !leaf && leaves && done > 0 && done < leaves ? ' is-part' : ''
    return `<div class="mini-stack">
      <div class="mini-node${leaf ? ' is-leaf' : ''}${on}${part}">
        <span class="mini-title">${esc(node && node.title)}</span>
        <span class="mini-score">${esc(score)}</span>
      </div>
      ${kidsWrap}
    </div>`
  }

  function renderMiniTree(preview) {
    const tops = (preview && preview.children) || []
    if (!tops.length) return renderMiniNode(preview)
    if (tops.length === 1) return renderMiniNode(tops[0])
    const kids = tops.map((n) => `<div class="mini-kid">${renderMiniNode(n)}</div>`).join('')
    return `<div class="mini-kids is-forest">${kids}</div>`
  }

  function renderFileCard(project) {
    const tasks = E.flattenTasks([project])
    const preview = E.previewTree(project)
    const risk = E.rollupStatus(tasks) === 'at_risk' ? ' is-risk' : ''
    return `<button type="button" class="file-card${risk}" data-project-id="${esc(project.id)}">
      <div class="file-sheet">
        <span class="file-fold"></span>
        <div class="file-preview">${renderMiniTree(preview)}</div>
      </div>
      <span class="file-name">${esc(project.title)}</span>
      <span class="file-meta">${esc(E.nodeCount('project', project))} 节点</span>
    </button>`
  }

  function renderFiles(projects) {
    const list = projects || []
    if (!list.length) return '<p class="column-empty">暂无项目</p>'
    return `<div class="file-grid">${list.map(renderFileCard).join('')}</div>`
  }

  function fillClass(fill) {
    if (fill === 'full') return ' is-on'
    if (fill === 'part') return ' is-part'
    return ''
  }

  function renderMapNode(node) {
    const clickable = node.hasKids || node.hasProc
    const score = node.leaf
      ? `<span class="tree-mark">${esc(node.progress)}</span>`
      : `<span class="tree-score">${esc(node.progress)}/${esc(node.leafCount)}</span>`
    const owner = node.ownerName
      ? `<span class="tree-owner">${esc(node.ownerName)}</span>`
      : ''
    const fill = fillClass(node.fill)
    const barPct = !node.leaf && node.leafCount ? Math.round((node.progress / node.leafCount) * 100) : 0
    const bar = !node.leaf
      ? `<span class="tree-bar"><span class="tree-bar-fill" style="width:${esc(barPct)}%"></span></span>`
      : ''
    const fold = clickable
      ? `<button type="button" class="tree-fold${node.open ? ' is-open' : ''}" data-node-id="${esc(node.id)}" data-has-kids="${node.hasKids ? '1' : '0'}" data-has-proc="${node.hasProc ? '1' : '0'}">${node.open ? '−' : '+'}</button>`
      : ''
    const clickAttrs = clickable
      ? ` type="button" data-node-id="${esc(node.id)}" data-has-kids="${node.hasKids ? '1' : '0'}" data-has-proc="${node.hasProc ? '1' : '0'}"`
      : ''
    const tag = clickable ? 'button' : 'div'
    return `<div class="map-item${fill}" style="left:${esc(node.x)}px;top:${esc(node.y)}px;width:${esc(node.w)}px">
      <${tag} class="tree-node kind-${esc(node.kind)}${node.leaf ? ' is-leaf' : ''}${fill}${clickable ? ' is-branch' : ''}${clickable && node.open ? ' is-open' : ''}"${clickAttrs}>
        <div class="tree-top">
          <div class="tree-main">
            <span class="tree-title">${esc(node.title)}</span>
            <span class="tree-meta">${owner}${score}</span>
          </div>
        </div>
        ${bar}
      </${tag}>
      ${fold}
    </div>`
  }

  function renderTreeBody(project) {
    const root = treeRoot(project)
    if (!root) return '<p class="column-empty">暂无节点</p>'
    const layout = E.mapLayout(root.kind, root.item, {
      collapsed: state.collapsed,
      nodeH: 72,
      procH: 72,
    })
    const byId = {}
    layout.nodes.forEach((n) => { byId[n.id] = n })
    const links = layout.edges.map((e) => {
      const a = byId[e.fromId]
      const b = byId[e.toId]
      if (!a || !b) return ''
      return `<path class="tree-link" d="${esc(E.mapLinkPath(a, b))}" fill="none"></path>`
    }).join('')
    const items = layout.nodes.map(renderMapNode).join('')
    const cam = state.cam
    return `<div class="tree-canvas">
      <div class="tree-world" style="width:${esc(layout.width)}px;height:${esc(layout.height)}px;transform:translate(${esc(cam.x)}px, ${esc(cam.y)}px) scale(${esc(cam.z)})">
        <svg class="tree-links" width="${esc(layout.width)}" height="${esc(layout.height)}" aria-hidden="true">${links}</svg>
        ${items}
      </div>
    </div>`
  }

  function renderTree(project) {
    return `<div class="tree-view">
      <div class="tree-toolbar">
        <button type="button" class="tree-back">返回</button>
        <h2 class="tree-heading">${esc(project.title)}</h2>
        <button type="button" class="tree-collapse">全部折叠</button>
        <button type="button" class="tree-expand">全部展开</button>
        <button type="button" class="tree-reset">复位</button>
        <span class="count">${esc(E.nodeCount('project', project))} 节点</span>
      </div>
      ${renderTreeBody(project)}
    </div>`
  }

  function renderBoard() {
    if (!els.explorer) return
    if (state.view === 'tree') {
      const project = findProject(state.openProjectId)
      if (!project) {
        state.view = 'files'
        state.openProjectId = null
      } else {
        els.explorer.innerHTML = renderTree(project)
        return
      }
    }
    els.explorer.innerHTML = renderFiles(state.projects)
  }

  function hydrate(data) {
    let projects
    try {
      projects = E.readProjects(data)
    } catch (err) {
      failLoad(err)
      return
    }
    state.meta = data.meta || {}
    state.projects = projects
    if (els.title && state.meta.title) els.title.textContent = state.meta.title
    if (els.period) els.period.textContent = state.meta.period || ''
    if (els.week) els.week.textContent = state.meta.week != null ? `第 ${state.meta.week} 周` : ''
    const sum = E.summarize(projects)
    if (els.summary) {
      els.summary.innerHTML = [
        summaryItem(sum.projects, '项目'),
        summaryItem(sum.tasks, '任务'),
      ].join('')
    }
    renderBoard()
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
    }, failLoad)
  }

  function insideCanvas(node) {
    while (node && node !== els.explorer) {
      if (classOf(node).indexOf('tree-canvas') !== -1) return true
      node = node.parentNode
    }
    return false
  }

  function isUiControl(node) {
    while (node && node !== els.explorer) {
      const cls = classOf(node)
      if (
        cls.indexOf('tree-fold') !== -1
        || cls.indexOf('tree-node') !== -1
        || cls.indexOf('tree-back') !== -1
        || cls.indexOf('tree-collapse') !== -1
        || cls.indexOf('tree-expand') !== -1
        || cls.indexOf('tree-reset') !== -1
        || cls.indexOf('file-card') !== -1
      ) return true
      node = node.parentNode
    }
    return false
  }

  function onExplorerClick(ev) {
    if (state.drag.moved) return
    let node = ev.target
    while (node && node !== els.explorer) {
      const cls = classOf(node)
      if (cls.indexOf('tree-back') !== -1) {
        state.view = 'files'
        state.openProjectId = null
        state.collapsed = {}
        resetCam()
        renderBoard()
        return
      }
      if (cls.indexOf('tree-collapse') !== -1) {
        applyAllFold(true)
        return
      }
      if (cls.indexOf('tree-expand') !== -1) {
        applyAllFold(false)
        return
      }
      if (cls.indexOf('tree-reset') !== -1) {
        resetCam()
        applyCam()
        return
      }
      if (cls.indexOf('file-card') !== -1) {
        const id = node.getAttribute('data-project-id')
        if (!id) return
        state.view = 'tree'
        state.openProjectId = id
        state.collapsed = {}
        resetCam()
        renderBoard()
        return
      }
      if (cls.indexOf('tree-fold') !== -1 || cls.indexOf('tree-node') !== -1) {
        const id = node.getAttribute('data-node-id')
        if (!id) return
        const hasKids = node.getAttribute('data-has-kids') === '1'
        const hasProc = node.getAttribute('data-has-proc') === '1'
        toggleNode(id, hasKids, hasProc)
        renderBoard()
        return
      }
      node = node.parentNode
    }
  }

  function onPointerDown(ev) {
    state.drag.moved = false
    if (!els.explorer || state.view !== 'tree') return
    if (isUiControl(ev.target)) return
    if (!insideCanvas(ev.target)) return
    const canvas = els.explorer.querySelector('.tree-canvas')
    if (!canvas) return
    state.drag = { on: true, x: ev.clientX, y: ev.clientY, moved: false }
    canvas.className = `${classOf(canvas).replace(/\s*is-panning\s*/g, ' ').trim()} is-panning`
    if (canvas.setPointerCapture && ev.pointerId != null) {
      try { canvas.setPointerCapture(ev.pointerId) } catch (err) { void err }
    }
  }

  function onPointerMove(ev) {
    if (!state.drag.on) return
    const dx = ev.clientX - state.drag.x
    const dy = ev.clientY - state.drag.y
    if (!state.drag.moved && (dx * dx + dy * dy) < 16) return
    state.drag.moved = true
    state.drag.x = ev.clientX
    state.drag.y = ev.clientY
    state.cam = E.panCam(state.cam, dx, dy)
    applyCam()
  }

  function onPointerUp(ev) {
    if (!state.drag.on) return
    state.drag.on = false
    const canvas = els.explorer && els.explorer.querySelector('.tree-canvas')
    if (canvas) canvas.className = classOf(canvas).replace(/\s*is-panning\s*/g, ' ').trim()
    if (ev && canvas && canvas.releasePointerCapture && ev.pointerId != null) {
      try { canvas.releasePointerCapture(ev.pointerId) } catch (err) { void err }
    }
  }

  function onWheel(ev) {
    if (state.view !== 'tree' || !insideCanvas(ev.target)) return
    const canvas = els.explorer.querySelector('.tree-canvas')
    if (!canvas) return
    ev.preventDefault()
    const rect = canvas.getBoundingClientRect()
    const px = ev.clientX - rect.left
    const py = ev.clientY - rect.top
    state.cam = E.zoomCam(state.cam, ev.deltaY > 0 ? 0.92 : 1.08, px, py)
    applyCam()
  }

  if (els.explorer) {
    els.explorer.onclick = onExplorerClick
    els.explorer.onpointerdown = onPointerDown
    els.explorer.onpointermove = onPointerMove
    els.explorer.onpointerup = onPointerUp
    els.explorer.onpointercancel = onPointerUp
    els.explorer.addEventListener('wheel', onWheel, { passive: false })
  }

  tickClock()
  window.setInterval(tickClock, 1000)
  window.setInterval(function () {
    load({ force: false })
  }, REFRESH_MS)
  load({ force: true })
})()

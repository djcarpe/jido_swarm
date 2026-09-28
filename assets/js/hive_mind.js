// The Hive mind: the shared graph, drawn live.
//
// A LiveView hook that keeps a force-directed picture of the Hive's memory
// graph. The server sends a snapshot once, then every delta as it lands on
// this pod, and the picture moves: a node written on another pod arrives in
// that pod's colour, a dropped one fades, a hot task glows.
//
// The layout is our own rather than a library's. Three hundred nodes make
// pairwise repulsion trivial, and two of the forces are ours — each origin
// pulls its nodes toward its own anchor, so the pods cluster visibly while
// edges still tie the clusters together, and a new node spawns beside its
// neighbours rather than at random. The simulation exposes add/remove/reheat
// so it could be swapped for d3-force without touching the rest.

const PALETTE = ["#2563eb", "#ea580c", "#16a34a", "#9333ea", "#0891b2", "#db2777", "#ca8a04", "#64748b"]

const SIM = {
  linkDistance: 70,
  linkStrength: 0.3,
  charge: -300,
  chargeMax: 400,
  originGravity: 0.02,
  center: 0.02,
  alphaDecay: 0.035,
  alphaMin: 0.005,
  velocityDecay: 0.6,
}

const CAP = 300
const PULSE_MS = 700
const TOMB_MS = 600
const LOST_MS = 2000

// One glyph per kind of entity, drawn inside the origin-coloured disc. Shapes
// rather than colours, because colour already says who wrote it.
const GLYPHS = {
  goal: "M0,-4.5 L1.3,-1.3 L4.5,-1.3 L1.9,0.7 L2.9,4 L0,2 L-2.9,4 L-1.9,0.7 L-4.5,-1.3 L-1.3,-1.3 Z",
  task: "M-3.5,-3.5 h7 v7 h-7 Z",
  claim: "M0,-4 A4,4 0 1,1 -0.01,-4 Z M0,-2 A2,2 0 1,0 0.01,-2 Z",
  agent: "M0,-4.5 L4,3.5 L-4,3.5 Z",
  insight: "M0,-4.5 L4.5,0 L0,4.5 L-4.5,0 Z",
  finding: "M0,-4.5 L4.5,0 L0,4.5 L-4.5,0 Z",
  question: "M-3.9,-2.25 L0,-4.5 L3.9,-2.25 L3.9,2.25 L0,4.5 L-3.9,2.25 Z",
  decision: "M0,-4.5 L4.3,-1.4 L2.6,3.6 L-2.6,3.6 L-4.3,-1.4 Z",
  probe: "M0,-4 A4,4 0 1,1 -0.01,-4 Z M0,-1.5 A1.5,1.5 0 1,0 0.01,-1.5 Z",
  ack: "M-3.5,0 L-1,2.5 L3.5,-2.5",
}

const EDGE_CLASS = {
  ABOUT: "dotted",
  ON: "dotted",
  DEPENDS_ON: "dashed arrow",
  SUBTASK_OF: "arrow",
  IN_GOAL: "arrow",
  CONTRADICTS: "contra",
  SUPPORTS: "support",
  CLAIMS: "thick",
  ACKS: "acks arrow",
}

// ---------------------------------------------------------------------------
// The store: what is on the canvas
// ---------------------------------------------------------------------------

class Graph {
  constructor() {
    this.nodes = new Map()
    this.edges = new Map()
    this.adj = new Map()
  }

  put(node) {
    const existing = this.nodes.get(node.key)
    if (existing) {
      Object.assign(existing, node, {x: existing.x, y: existing.y, vx: existing.vx, vy: existing.vy})
      return {node: existing, isNew: false}
    }
    const fresh = {...node, x: NaN, y: NaN, vx: 0, vy: 0}
    this.nodes.set(node.key, fresh)
    this.adj.set(node.key, new Set())
    return {node: fresh, isNew: true}
  }

  link(edge) {
    if (this.edges.has(edge.id)) {
      Object.assign(this.edges.get(edge.id), edge)
      return false
    }
    this.edges.set(edge.id, {...edge})
    this.adj.get(edge.from)?.add(edge.id)
    this.adj.get(edge.to)?.add(edge.id)
    return true
  }

  unlink(id) {
    const edge = this.edges.get(id)
    if (!edge) return
    this.edges.delete(id)
    this.adj.get(edge.from)?.delete(id)
    this.adj.get(edge.to)?.delete(id)
  }

  drop(key) {
    const node = this.nodes.get(key)
    if (!node) return
    for (const id of [...(this.adj.get(key) || [])]) this.unlink(id)
    this.adj.delete(key)
    this.nodes.delete(key)
  }

  neighbours(key) {
    const out = []
    for (const id of this.adj.get(key) || []) {
      const e = this.edges.get(id)
      const other = e.from === key ? e.to : e.from
      const n = this.nodes.get(other)
      if (n) out.push(n)
    }
    return out
  }

  degree(key) {
    return this.adj.get(key)?.size || 0
  }

  // Past the cap the oldest node goes, edges with it — the canvas stays
  // newest-first, like the snapshot it started from.
  evict(keep) {
    while (this.nodes.size > CAP) {
      let oldest = null
      for (const n of this.nodes.values()) {
        if (n.key === keep || n.pinned) continue
        if (!oldest || (n.ts || 0) < (oldest.ts || 0)) oldest = n
      }
      if (!oldest) return []
      this.drop(oldest.key)
    }
  }
}

// ---------------------------------------------------------------------------
// The simulation
// ---------------------------------------------------------------------------

class Simulation {
  constructor(graph) {
    this.graph = graph
    this.alpha = 0
    this.alphaTarget = 0
    this.width = 600
    this.height = 400
    this.anchors = new Map()
  }

  resize(width, height) {
    this.width = width
    this.height = height
    this.placeAnchors()
  }

  // One anchor per origin on a ring around the centre. The local origin is
  // first in the palette and so takes the top; the rest follow clockwise.
  placeAnchors(origins = [...this.anchors.keys()]) {
    const n = Math.max(origins.length, 1)
    const r = Math.min(this.width, this.height) * 0.28
    origins.forEach((origin, i) => {
      const a = -Math.PI / 2 + (2 * Math.PI * i) / n
      this.anchors.set(origin, {x: this.width / 2 + r * Math.cos(a), y: this.height / 2 + r * Math.sin(a)})
    })
  }

  anchor(origin) {
    if (!this.anchors.has(origin)) this.placeAnchors([...this.anchors.keys(), origin])
    return this.anchors.get(origin)
  }

  reheat(alpha = 0.3) {
    this.alpha = Math.max(this.alpha, alpha)
  }

  // A new node starts where it belongs: beside its neighbours if any are on
  // the canvas, else near its origin's anchor. Never at the same point as
  // another node, or the repulsion has no direction to push.
  place(node) {
    const near = this.graph.neighbours(node.key).filter(n => !Number.isNaN(n.x))
    let x, y
    if (near.length > 0) {
      x = near.reduce((s, n) => s + n.x, 0) / near.length
      y = near.reduce((s, n) => s + n.y, 0) / near.length
    } else {
      const a = this.anchor(node.origin || "?")
      x = a.x
      y = a.y
    }
    const jitter = () => (Math.random() - 0.5) * 30
    node.x = x + jitter()
    node.y = y + jitter()
    node.vx = 0
    node.vy = 0
  }

  radius(node) {
    return 8 + 6 * Math.min(Math.max(node.heat || 0, 0), 2)
  }

  tick() {
    const nodes = [...this.graph.nodes.values()]
    const alpha = this.alpha
    const cx = this.width / 2
    const cy = this.height / 2
    const maxD2 = SIM.chargeMax * SIM.chargeMax

    for (const n of nodes) if (Number.isNaN(n.x)) this.place(n)

    // Repulsion: every pair, with a distance cap so far-apart clusters do
    // not keep drifting.
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i]
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let d2 = dx * dx + dy * dy
        if (d2 > maxD2) continue
        if (d2 < 1e-6) {
          dx = (Math.random() - 0.5) * 1e-3
          dy = (Math.random() - 0.5) * 1e-3
          d2 = dx * dx + dy * dy
        }
        const f = (SIM.charge * alpha) / Math.max(d2, 100)
        const fx = dx * f
        const fy = dy * f
        a.vx += fx
        a.vy += fy
        b.vx -= fx
        b.vy -= fy
      }
    }

    // Springs along edges, split by degree so a hub does not get dragged by
    // every leaf at once.
    for (const e of this.graph.edges.values()) {
      const a = this.graph.nodes.get(e.from)
      const b = this.graph.nodes.get(e.to)
      if (!a || !b) continue
      let dx = b.x - a.x
      let dy = b.y - a.y
      const d = Math.max(Math.sqrt(dx * dx + dy * dy), 1)
      const l = ((d - SIM.linkDistance) / d) * alpha * SIM.linkStrength
      dx *= l
      dy *= l
      const da = this.graph.degree(a.key)
      const db = this.graph.degree(b.key)
      const bias = da / (da + db || 1)
      b.vx -= dx * (1 - bias)
      b.vy -= dy * (1 - bias)
      a.vx += dx * bias
      a.vy += dy * bias
    }

    for (const n of nodes) {
      // Toward the origin's anchor: what makes "written by many pods" a shape.
      const a = this.anchor(n.origin || "?")
      n.vx += (a.x - n.x) * SIM.originGravity * alpha
      n.vy += (a.y - n.y) * SIM.originGravity * alpha
      // And weakly toward the middle, so nothing drifts off the canvas.
      n.vx += (cx - n.x) * SIM.center * alpha
      n.vy += (cy - n.y) * SIM.center * alpha
    }

    // One pass of collision: enough at this size to keep discs apart.
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i]
      const ra = this.radius(a)
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j]
        const min = ra + this.radius(b) + 4
        const dx = b.x - a.x
        const dy = b.y - a.y
        const d2 = dx * dx + dy * dy
        if (d2 >= min * min || d2 === 0) continue
        const d = Math.sqrt(d2)
        const push = ((min - d) / d) * 0.5
        a.x -= dx * push
        a.y -= dy * push
        b.x += dx * push
        b.y += dy * push
      }
    }

    for (const n of nodes) {
      if (n.dragging) {
        n.vx = 0
        n.vy = 0
        continue
      }
      n.vx *= SIM.velocityDecay
      n.vy *= SIM.velocityDecay
      n.x += n.vx
      n.y += n.vy
    }

    this.alpha += (this.alphaTarget - this.alpha) * SIM.alphaDecay
    if (this.alphaTarget === 0 && this.alpha < SIM.alphaMin) this.alpha = 0
    return this.alpha > 0
  }
}

// ---------------------------------------------------------------------------
// The renderer
// ---------------------------------------------------------------------------

const SVG = "http://www.w3.org/2000/svg"
const el = (tag, attrs = {}) => {
  const e = document.createElementNS(SVG, tag)
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v)
  return e
}

class Renderer {
  constructor(container, graph, sim, callbacks) {
    this.container = container
    this.graph = graph
    this.sim = sim
    this.callbacks = callbacks
    this.colors = {}
    this.transform = {x: 0, y: 0, k: 1}
    this.filters = {kinds: null, origins: null, windowMs: null, remoteOnly: false}
    this.me = container.dataset.me || ""
    this.highlight = null
    this.selected = null
    this.nodeEls = new Map()
    this.edgeEls = new Map()

    this.svg = el("svg", {class: "hm-svg", width: "100%", height: "100%"})
    const defs = el("defs")
    const marker = el("marker", {
      id: "hm-arrow",
      viewBox: "0 0 10 10",
      refX: "10",
      refY: "5",
      markerWidth: "6",
      markerHeight: "6",
      orient: "auto-start-reverse",
    })
    marker.appendChild(el("path", {d: "M0,0 L10,5 L0,10 Z", class: "hm-arrowhead"}))
    defs.appendChild(marker)
    this.svg.appendChild(defs)

    this.viewport = el("g", {class: "hm-viewport"})
    this.edgeLayer = el("g", {class: "hm-edges"})
    this.nodeLayer = el("g", {class: "hm-nodes"})
    this.viewport.appendChild(this.edgeLayer)
    this.viewport.appendChild(this.nodeLayer)
    this.svg.appendChild(this.viewport)

    this.banner = document.createElement("div")
    this.banner.className = "hm-banner"
    container.appendChild(this.svg)
    container.appendChild(this.banner)

    this.bindPointer()
  }

  color(origin) {
    return this.colors[origin] || PALETTE[PALETTE.length - 1]
  }

  setColors(colors) {
    if (!colors) return
    this.colors = {...this.colors, ...colors}
    for (const [key, g] of this.nodeEls) {
      const n = this.graph.nodes.get(key)
      if (n) g.querySelector(".hm-disc").setAttribute("fill", this.color(n.origin))
    }
  }

  // --- nodes ---------------------------------------------------------------

  ensureNode(node) {
    let g = this.nodeEls.get(node.key)
    if (g) {
      this.decorate(g, node)
      return g
    }
    g = el("g", {class: "hm-node", "data-key": node.key})
    g.appendChild(el("circle", {class: "hm-halo", r: 0}))
    g.appendChild(el("circle", {class: "hm-disc", r: 8}))
    g.appendChild(el("path", {class: "hm-glyph", d: GLYPHS[node.kind] || "M0,-2 A2,2 0 1,1 -0.01,-2 Z"}))
    const label = el("text", {class: "hm-label", dy: "-12", "text-anchor": "middle"})
    g.appendChild(label)
    const title = el("title")
    g.appendChild(title)
    this.nodeLayer.appendChild(g)
    this.nodeEls.set(node.key, g)
    this.decorate(g, node)
    return g
  }

  decorate(g, node) {
    const r = this.sim.radius(node)
    g.querySelector(".hm-disc").setAttribute("fill", this.color(node.origin))
    g.querySelector(".hm-disc").setAttribute("r", 8)
    g.querySelector(".hm-halo").setAttribute("r", node.heat > 0.05 ? r + 4 : 0)
    g.querySelector(".hm-halo").setAttribute("fill", this.color(node.origin))
    g.querySelector(".hm-glyph").setAttribute("d", GLYPHS[node.kind] || "M0,-2 A2,2 0 1,1 -0.01,-2 Z")
    g.querySelector(".hm-label").textContent = node.caption || node.key
    g.querySelector("title").textContent =
      `${node.kind} · ${node.key}\nwritten by ${node.origin || "?"} · seq ${node.seq ?? "?"}` +
      (node.heat > 0.05 ? `\nheat ${node.heat.toFixed(2)}` : "")
    g.classList.toggle("hm-ghost", !!node.ghost)
    g.classList.toggle("hm-remote", !!node.origin && node.origin !== this.me)
    g.classList.toggle("hm-selected", node.key === this.selected)
    g.classList.toggle("hm-highlight", !!this.highlight && this.highlight.has(node.key))
  }

  // `cls` may name several classes; DOMTokenList takes them one at a time.
  pulse(key, cls = "hm-pulse", ms = PULSE_MS) {
    const g = this.nodeEls.get(key)
    if (!g) return
    const classes = cls.split(/\s+/).filter(Boolean)
    g.classList.remove(...classes)
    void g.getBoundingClientRect()
    g.classList.add(...classes)
    setTimeout(() => g.classList.remove(...classes), ms)
  }

  removeNode(key, fade) {
    const g = this.nodeEls.get(key)
    if (!g) return
    this.nodeEls.delete(key)
    if (fade) {
      g.classList.add("hm-tomb")
      setTimeout(() => g.remove(), TOMB_MS)
    } else {
      g.remove()
    }
  }

  // --- edges ---------------------------------------------------------------

  ensureEdge(edge) {
    let line = this.edgeEls.get(edge.id)
    if (line) return line
    const cls = EDGE_CLASS[edge.type] || ""
    line = el("line", {class: `hm-edge ${cls}`, "data-id": edge.id})
    if (cls.includes("arrow")) line.setAttribute("marker-end", "url(#hm-arrow)")
    const title = el("title")
    title.textContent = `${edge.type} · written by ${edge.origin || "?"}`
    line.appendChild(title)
    this.edgeLayer.appendChild(line)
    this.edgeEls.set(edge.id, line)
    return line
  }

  removeEdge(id) {
    const line = this.edgeEls.get(id)
    if (!line) return
    this.edgeEls.delete(id)
    line.remove()
  }

  // --- filters -------------------------------------------------------------

  visible(node) {
    const f = this.filters
    if (f.kinds && !f.kinds.has(node.kind)) return false
    if (f.origins && !f.origins.has(node.origin)) return false
    if (f.remoteOnly && node.origin === this.me) return false
    if (f.windowMs && node.ts && Date.now() - node.ts > f.windowMs) return false
    return true
  }

  // --- drawing -------------------------------------------------------------

  draw() {
    const {x, y, k} = this.transform
    this.viewport.setAttribute("transform", `translate(${x},${y}) scale(${k})`)
    const showLabels = k > 0.8
    const hidden = new Set()

    for (const [key, g] of this.nodeEls) {
      const n = this.graph.nodes.get(key)
      if (!n || Number.isNaN(n.x)) continue
      const on = this.visible(n)
      if (!on) hidden.add(key)
      g.style.display = on ? "" : "none"
      g.setAttribute("transform", `translate(${n.x.toFixed(1)},${n.y.toFixed(1)})`)
      g.querySelector(".hm-label").style.display = showLabels || n.key === this.selected ? "" : "none"
    }

    for (const [id, line] of this.edgeEls) {
      const e = this.graph.edges.get(id)
      const a = e && this.graph.nodes.get(e.from)
      const b = e && this.graph.nodes.get(e.to)
      if (!a || !b || Number.isNaN(a.x) || Number.isNaN(b.x) || hidden.has(a.key) || hidden.has(b.key)) {
        line.style.display = "none"
        continue
      }
      line.style.display = ""
      // Stop the line at the disc's edge so arrowheads are visible.
      const dx = b.x - a.x
      const dy = b.y - a.y
      const d = Math.max(Math.sqrt(dx * dx + dy * dy), 1)
      const rb = this.sim.radius(b) + 1
      line.setAttribute("x1", a.x.toFixed(1))
      line.setAttribute("y1", a.y.toFixed(1))
      line.setAttribute("x2", (b.x - (dx / d) * rb).toFixed(1))
      line.setAttribute("y2", (b.y - (dy / d) * rb).toFixed(1))
    }
  }

  setBanner(text) {
    this.banner.textContent = text || ""
    this.banner.style.display = text ? "" : "none"
  }

  // --- pointer: pan, zoom, drag, click -------------------------------------

  toWorld(clientX, clientY) {
    const rect = this.svg.getBoundingClientRect()
    const {x, y, k} = this.transform
    return {x: (clientX - rect.left - x) / k, y: (clientY - rect.top - y) / k}
  }

  bindPointer() {
    let drag = null

    this.svg.addEventListener("pointerdown", ev => {
      const g = ev.target.closest(".hm-node")
      const start = {x: ev.clientX, y: ev.clientY}
      if (g) {
        const node = this.graph.nodes.get(g.dataset.key)
        if (!node) return
        node.dragging = true
        drag = {kind: "node", node, start, moved: false}
        this.sim.alphaTarget = 0.3
        this.sim.reheat(0.3)
        this.callbacks.wake()
      } else {
        drag = {kind: "pan", start, origin: {...this.transform}, moved: false}
      }
      this.svg.setPointerCapture(ev.pointerId)
      ev.preventDefault()
    })

    this.svg.addEventListener("pointermove", ev => {
      if (!drag) return
      const dx = ev.clientX - drag.start.x
      const dy = ev.clientY - drag.start.y
      if (Math.abs(dx) + Math.abs(dy) > 3) drag.moved = true
      if (drag.kind === "node") {
        const p = this.toWorld(ev.clientX, ev.clientY)
        drag.node.x = p.x
        drag.node.y = p.y
      } else {
        this.transform = {...this.transform, x: drag.origin.x + dx, y: drag.origin.y + dy}
        this.draw()
      }
    })

    const finish = ev => {
      if (!drag) return
      if (drag.kind === "node") {
        drag.node.dragging = false
        drag.node.pinned = drag.moved
        this.sim.alphaTarget = 0
        if (!drag.moved) this.callbacks.select(drag.node.key)
      }
      drag = null
      try {
        this.svg.releasePointerCapture(ev.pointerId)
      } catch (_) {}
    }
    this.svg.addEventListener("pointerup", finish)
    this.svg.addEventListener("pointercancel", finish)

    this.svg.addEventListener("dblclick", ev => {
      const g = ev.target.closest(".hm-node")
      if (g) this.callbacks.expand(g.dataset.key)
    })

    this.svg.addEventListener(
      "wheel",
      ev => {
        ev.preventDefault()
        const rect = this.svg.getBoundingClientRect()
        const px = ev.clientX - rect.left
        const py = ev.clientY - rect.top
        const {x, y, k} = this.transform
        const factor = Math.exp(-ev.deltaY * 0.0015)
        const nk = Math.min(Math.max(k * factor, 0.2), 4)
        // Zoom about the cursor: the world point under it stays put.
        this.transform = {k: nk, x: px - ((px - x) / k) * nk, y: py - ((py - y) / k) * nk}
        this.draw()
      },
      {passive: false},
    )
  }

  fit() {
    const nodes = [...this.graph.nodes.values()].filter(n => !Number.isNaN(n.x))
    if (nodes.length === 0) return
    const xs = nodes.map(n => n.x)
    const ys = nodes.map(n => n.y)
    const minX = Math.min(...xs) - 30
    const maxX = Math.max(...xs) + 30
    const minY = Math.min(...ys) - 30
    const maxY = Math.max(...ys) + 30
    const w = this.svg.clientWidth || this.sim.width
    const h = this.svg.clientHeight || this.sim.height
    const k = Math.min(Math.max(Math.min(w / (maxX - minX), h / (maxY - minY)), 0.2), 2)
    this.transform = {k, x: (w - (minX + maxX) * k) / 2, y: (h - (minY + maxY) * k) / 2}
    this.draw()
  }
}

// ---------------------------------------------------------------------------
// The hook
// ---------------------------------------------------------------------------

export const HiveMind = {
  mounted() {
    this.graph = new Graph()
    this.sim = new Simulation(this.graph)
    this.renderer = new Renderer(this.el, this.graph, this.sim, {
      wake: () => this.wake(),
      select: key => this.pushEvent("hive_select", {key}),
      expand: key => this.pushEvent("hive_expand_node", {key}),
    })
    this.running = false
    this.frames = 0

    this.resize()
    this.observer = new ResizeObserver(() => {
      this.resize()
      this.sim.reheat(0.2)
      this.wake()
    })
    this.observer.observe(this.el)

    // Expanded is server state (the class comes from the template), so a
    // re-render never undoes it; the hook only reacts to the class changing.
    this.el.addEventListener("hive:fit", () => this.renderer.fit())
    // The frame around this element carries the classes; this element is
    // never re-rendered, so its own attributes are whatever the hook set.
    this.frame = this.el.parentElement
    this.expanded = this.frame.classList.contains("hm-expanded")
    this.classes = new MutationObserver(() => this.onClassChange())
    this.classes.observe(this.frame, {attributes: true, attributeFilter: ["class"]})
    this.onKey = ev => {
      if (ev.key === "Escape" && this.frame.classList.contains("hm-expanded")) this.pushEvent("hive_toggle_expand", {})
    }
    window.addEventListener("keydown", this.onKey)

    // A fault in the drawing must never reach LiveView's dispatch: an
    // exception here would abort the message it came in on, page and all.
    const guard = (name, fn) =>
      this.handleEvent(name, payload => {
        try {
          fn(payload)
        } catch (e) {
          console.error(`hive mind: ${name} failed`, e)
        }
      })
    guard("hive:snapshot", payload => this.snapshot(payload))
    guard("hive:delta", payload => this.delta(payload))
    guard("hive:patch", payload => this.patch(payload))
    guard("hive:outcome", payload => this.outcome(payload))
    guard("hive:heat", payload => this.heat(payload))
    guard("hive:filter", payload => this.filter(payload))
    guard("hive:highlight", payload => this.highlightKeys(payload))
    guard("hive:select", payload => this.select(payload.key))

    this.pushEvent("hive_snapshot", {})
  },

  reconnected() {
    this.pushEvent("hive_snapshot", {})
  },

  destroyed() {
    this.observer?.disconnect()
    this.classes?.disconnect()
    document.body.classList.remove("hm-expanded-body")
    window.removeEventListener("keydown", this.onKey)
    this.running = false
  },

  resize() {
    const w = this.el.clientWidth || 600
    const h = this.el.clientHeight || 400
    this.sim.resize(w, h)
  },

  onClassChange() {
    const expanded = this.frame.classList.contains("hm-expanded")
    document.body.classList.toggle("hm-expanded-body", expanded)
    if (expanded !== this.expanded) {
      this.expanded = expanded
      this.resize()
      this.sim.placeAnchors()
      this.sim.reheat(0.5)
      this.wake()
      setTimeout(() => this.renderer.fit(), 400)
    }
  },

  // --- server events -------------------------------------------------------

  snapshot({nodes, edges, truncated, total, me, colors}) {
    if (me) this.renderer.me = me
    this.renderer.setColors(colors)
    this.sim.placeAnchors(this.originsOf(nodes))

    const keep = new Set(nodes.map(n => n.key))
    for (const key of [...this.graph.nodes.keys()]) {
      if (!keep.has(key)) {
        this.graph.drop(key)
        this.renderer.removeNode(key, false)
      }
    }
    for (const id of [...this.graph.edges.keys()]) {
      this.graph.unlink(id)
      this.renderer.removeEdge(id)
    }
    for (const n of nodes) this.renderer.ensureNode(this.graph.put(n).node)
    for (const e of edges) {
      if (this.graph.link(e)) this.renderer.ensureEdge(e)
    }
    this.renderer.setBanner(truncated ? `newest ${nodes.length} of ${total} entities` : "")
    this.sim.reheat(1)
    this.wake()
    setTimeout(() => this.renderer.fit(), 1200)
  },

  delta({origin, local, ops, colors}) {
    this.renderer.setColors(colors)
    if (origin && !this.sim.anchors.has(origin)) this.sim.placeAnchors([...this.sim.anchors.keys(), origin])
    let touched = false

    for (const op of ops) {
      switch (op.op) {
        case "put_node": {
          const {node, isNew} = this.graph.put(op.node)
          if (isNew) this.sim.place(node)
          this.renderer.ensureNode(node)
          this.renderer.pulse(node.key, local ? "hm-pulse" : "hm-pulse hm-pulse-remote")
          if (isNew) {
            this.graph.evict(node.key)
            this.sim.reheat(0.3)
          }
          touched = true
          break
        }
        case "drop_node": {
          this.renderer.removeNode(op.key, true)
          this.graph.drop(op.key)
          touched = true
          break
        }
        case "put_edge": {
          // The graph itself makes a placeholder for an end it has not seen.
          for (const key of [op.edge.from, op.edge.to]) {
            if (!this.graph.nodes.has(key)) {
              const {node} = this.graph.put({key, kind: key.split(":")[0], labels: [], caption: key, origin, ghost: true, heat: 0})
              this.sim.place(node)
              this.renderer.ensureNode(node)
            }
          }
          if (this.graph.link(op.edge)) {
            this.renderer.ensureEdge(op.edge)
            this.sim.reheat(0.2)
          }
          touched = true
          break
        }
        case "drop_edge": {
          this.graph.unlink(op.id)
          this.renderer.removeEdge(op.id)
          touched = true
          break
        }
      }
    }
    // Stale renderer entries after eviction.
    for (const key of [...this.renderer.nodeEls.keys()]) {
      if (!this.graph.nodes.has(key)) this.renderer.removeNode(key, false)
    }
    for (const id of [...this.renderer.edgeEls.keys()]) {
      if (!this.graph.edges.has(id)) this.renderer.removeEdge(id)
    }
    if (touched) this.wake()
  },

  patch({nodes = [], edges = []}) {
    for (const n of nodes) {
      const {node, isNew} = this.graph.put(n)
      if (isNew) this.sim.place(node)
      this.renderer.ensureNode(node)
    }
    for (const e of edges) {
      if (this.graph.nodes.has(e.from) && this.graph.nodes.has(e.to) && this.graph.link(e)) this.renderer.ensureEdge(e)
    }
    this.sim.reheat(0.3)
    this.wake()
  },

  outcome({superseded = [], tombstoned = []}) {
    for (const key of [...superseded, ...tombstoned]) this.renderer.pulse(key, "hm-lost", LOST_MS)
  },

  heat(heat) {
    for (const n of this.graph.nodes.values()) {
      const h = heat[n.key] || 0
      if (h !== n.heat) {
        n.heat = h
        const g = this.renderer.nodeEls.get(n.key)
        if (g) this.renderer.decorate(g, n)
      }
    }
    this.wake()
  },

  filter({kinds, origins, window_ms, remote_only}) {
    this.renderer.filters = {
      kinds: kinds && kinds.length ? new Set(kinds) : null,
      origins: origins && origins.length ? new Set(origins) : null,
      windowMs: window_ms || null,
      remoteOnly: !!remote_only,
    }
    this.renderer.draw()
  },

  highlightKeys({keys, label}) {
    this.renderer.highlight = keys && keys.length ? new Set(keys) : null
    for (const [key, g] of this.renderer.nodeEls) {
      const n = this.graph.nodes.get(key)
      if (n) this.renderer.decorate(g, n)
    }
    this.renderer.setBanner(label || "")
  },

  select(key) {
    this.renderer.selected = key || null
    for (const [k, g] of this.renderer.nodeEls) {
      const n = this.graph.nodes.get(k)
      if (n) this.renderer.decorate(g, n)
    }
    this.renderer.draw()
  },

  // --- the loop ------------------------------------------------------------

  originsOf(nodes) {
    const seen = [this.renderer.me]
    for (const n of nodes) if (n.origin && !seen.includes(n.origin)) seen.push(n.origin)
    return seen.filter(Boolean)
  },

  wake() {
    if (this.running) return
    this.running = true
    const step = () => {
      if (!this.running) return
      const alive = this.sim.tick()
      this.renderer.draw()
      if (alive) requestAnimationFrame(step)
      else this.running = false
    }
    requestAnimationFrame(step)
  },
}

// Exposed for tests; the hook is the only thing app.js needs.
export {Graph, Simulation, PALETTE}

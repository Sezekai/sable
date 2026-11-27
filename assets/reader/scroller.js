// Sable: scroll mode as one long page. Every part of the book is a frame,
// stacked top to bottom with a divider naming the chapter between them; parts
// are loaded as they come near and let go when far away. It stands in for
// foliate's paginator (same events and methods), so everything above it
// (positions, contents, search, highlights) works the same.

const setImportant = (el, styles) => {
    for (const [k, v] of Object.entries(styles)) el.style.setProperty(k, v, 'important')
}

// A range covering what's visible in a frame between two heights (document px).
const visibleRange = (doc, top, bottom) => {
    const x = Math.max(1, Math.min(doc.documentElement.clientWidth - 1, doc.documentElement.clientWidth / 2))
    const at = y => {
        const r = doc.caretRangeFromPoint?.(x, y)
        if (r) return r
        const el = doc.elementFromPoint?.(x, y)
        if (!el) return null
        const rr = doc.createRange()
        rr.selectNodeContents(el)
        rr.collapse(true)
        return rr
    }
    const h = doc.documentElement.scrollHeight
    const a = at(Math.max(1, Math.min(h - 1, top + 2)))
    const b = at(Math.max(1, Math.min(h - 1, bottom - 2)))
    if (!a) {
        const r = doc.createRange()
        r.selectNodeContents(doc.body)
        r.collapse(true)
        return r
    }
    const r = doc.createRange()
    r.setStart(a.startContainer, a.startOffset)
    if (b && a.compareBoundaryPoints(Range.START_TO_START, b) <= 0) r.setEnd(b.startContainer, b.startOffset)
    else r.collapse(true)
    return r
}

export class Scroller extends HTMLElement {
    static observedAttributes = ['gap', 'max-inline-size', 'flow', 'margin']
    #root = this.attachShadow({ mode: 'closed' })
    #container
    #parts = []
    #byIndex = new Map()
    #styles
    #index = -1
    #io
    #ro
    #pxPerByte = 0.55
    #pending = null
    #reportTimer = 0
    #lastReport = 0
    #cleanTimer = 0
    #expect = -1
    /** Chapter names by part of the book (set by Sable). */
    labels = new Map()

    constructor() {
        super()
        this.#root.innerHTML = `<style>
            :host { display: block; position: relative; width: 100%; height: 100%; }
            #container { position: absolute; inset: 0; overflow-y: auto; overflow-x: hidden;
                scrollbar-width: none; overflow-anchor: none; }
            .part { position: relative; }
            .box { position: relative; overflow: hidden; }
            .box iframe { display: block; border: 0; width: 100%; }
            .divider { box-sizing: border-box; display: flex; align-items: center; gap: 16px;
                margin: 0 auto; padding: 18px 24px 14px; color: var(--muted, #888);
                font: 600 12px/1.3 system-ui, "Segoe UI", sans-serif; letter-spacing: .08em; text-transform: uppercase; }
            .divider span { max-width: 70%; text-align: center; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .divider::before, .divider::after { content: ''; flex: 1; height: 1px; background: currentColor; opacity: .35; }
            .divider.plain span { display: none; }
        </style><div id="container"></div>`
        this.#container = this.#root.getElementById('container')
        this.#container.addEventListener('scroll', () => this.#onScroll(), { passive: true })
        this.#io = new IntersectionObserver(entries => {
            for (const e of entries) if (e.isIntersecting) this.#load(e.target.sablePart)
        }, { root: this.#container, rootMargin: '150% 0px' })
        this.#ro = new ResizeObserver(() => this.#layoutAll())
    }
    connectedCallback() { this.#ro.observe(this) }
    attributeChangedCallback() { this.#layoutAll() }

    open(book) {
        this.bookDir = book.dir
        this.sections = book.sections
        book.transformTarget?.addEventListener('data', ({ detail }) => {
            if (detail.type !== 'text/css') return
            const w = innerWidth, h = innerHeight
            detail.data = Promise.resolve(detail.data).then(data => data
                .replace(/(?<=[{\s;])-epub-/gi, '')
                .replace(/(\d*\.?\d+)vw/gi, (_, d) => parseFloat(d) * w / 100 + 'px')
                .replace(/(\d*\.?\d+)vh/gi, (_, d) => parseFloat(d) * h / 100 + 'px'))
        })
        let first = true
        this.sections.forEach((section, index) => {
            if (section.linear === 'no' || !section.load) return
            const el = document.createElement('div')
            el.className = 'part'
            const divider = document.createElement('div')
            divider.className = 'divider'
            divider.innerHTML = '<span></span>'
            if (first) divider.style.display = 'none'
            first = false
            const box = document.createElement('div')
            box.className = 'box'
            const part = { index, el, box, divider, frame: null, doc: null, h: 0, loading: null, overlayer: null, $styles: null }
            part.h = this.#estimate(part)
            box.style.height = `${part.h}px`
            el.append(divider, box)
            el.sablePart = part
            this.#container.append(el)
            this.#parts.push(part)
            this.#byIndex.set(index, part)
            this.#io.observe(el)
        })
        this.refreshLabels()
    }

    /** Puts the chapter names on the dividers. */
    refreshLabels() {
        for (const p of this.#parts) {
            const name = this.labels.get(p.index) ?? ''
            p.divider.querySelector('span').textContent = name
            p.divider.classList.toggle('plain', !name)
        }
    }

    #estimate(p) {
        const size = this.sections[p.index]?.size ?? 4000
        return Math.max(240, Math.round(size * this.#pxPerByte))
    }

    #partFor(index) {
        if (this.#byIndex.has(index)) return this.#byIndex.get(index)
        // A part that isn't read in order: the nearest one that is.
        return this.#parts.find(p => p.index > index) ?? this.#parts.at(-1)
    }

    // The sizes the pages are set out with (as the paginator works them out).
    #metrics() {
        const width = this.#container.clientWidth || innerWidth
        const height = this.#container.clientHeight || innerHeight
        const g = (parseFloat(this.getAttribute('gap') ?? '6') || 6) / 100
        const gap = -g / (g - 1) * width
        const maxInline = parseFloat(this.getAttribute('max-inline-size') ?? '720') || 720
        return { width, height, gap, columnWidth: maxInline }
    }

    #layoutDoc(p) {
        const doc = p.doc
        if (!doc?.documentElement || !doc.body) return
        const { height, gap, columnWidth } = this.#metrics()
        setImportant(doc.documentElement, {
            'box-sizing': 'border-box', 'padding': `0 ${gap}px`, 'column-width': 'auto',
            'height': 'auto', 'width': 'auto', 'overflow': 'hidden',
        })
        setImportant(doc.body, { 'max-width': `${columnWidth}px`, 'margin': 'auto' })
        for (const el of doc.body.querySelectorAll('img, svg, video')) {
            const { maxWidth } = doc.defaultView.getComputedStyle(el)
            setImportant(el, {
                'max-height': `${Math.round(height * 0.92)}px`,
                'max-width': maxWidth !== 'none' && maxWidth !== '0px' ? maxWidth : '100%',
                'object-fit': 'contain', 'box-sizing': 'border-box',
            })
        }
        p.divider.style.maxWidth = `${columnWidth + gap * 2}px`
    }

    #layoutAll() {
        for (const p of this.#parts) if (p.doc) { this.#layoutDoc(p); this.#measure(p) }
        if (!this.#parts.some(p => p.doc)) for (const p of this.#parts) p.divider.style.maxWidth = `${this.#metrics().columnWidth}px`
    }

    // A part's height follows its text; parts above the screen keep the reading
    // place still when they change size.
    // The text's own height: from the top of the first thing to the bottom of
    // the last, so blank space a book puts before or after a chapter (big
    // margins, a page-tall body) doesn't make a gap between chapters.
    #extent(doc) {
        const b = doc.body
        if (!b) return { trim: 0, h: doc.documentElement.scrollHeight }
        const r = doc.createRange()
        r.selectNodeContents(b)
        const rect = r.getBoundingClientRect()
        const cs = doc.defaultView.getComputedStyle(b)
        const padTop = parseFloat(cs.paddingTop) || 0, padBottom = parseFloat(cs.paddingBottom) || 0
        if (!(rect.height > 0)) return { trim: 0, h: Math.max(40, doc.documentElement.scrollHeight) }
        // Keep the body's own padding (Sable's chapter margins); drop the rest.
        const trim = Math.max(0, Math.floor(rect.top - padTop))
        return { trim, h: Math.ceil(rect.bottom + padBottom) - trim }
    }

    #measure(p) {
        if (!p.doc?.documentElement) return
        const ext = this.#extent(p.doc)
        if (ext.trim !== p.trim) {
            p.trim = ext.trim
            if (p.frame) {
                p.frame.style.marginTop = `${-ext.trim}px`
                p.frame.style.height = `${ext.h + ext.trim}px`
            }
        } else if (p.frame) p.frame.style.height = `${ext.h + ext.trim}px`
        // Highlights sit over the frame, moved up with it.
        if (p.overlayer) {
            p.overlayer.element.style.top = `${-ext.trim}px`
            p.overlayer.element.style.height = `${ext.h + ext.trim}px`
        }
        const h = Math.max(40, ext.h)
        if (Math.abs(h - p.h) < 1) return
        const c = this.#container
        const top = p.el.offsetTop
        const above = top + p.el.offsetHeight <= c.scrollTop + 1
        const old = p.h
        p.h = h
        p.box.style.height = `${h}px`
        p.overlayer?.redraw?.()
        if (above) {
            this.#setTop(c.scrollTop + h - old)
            this.onShift?.(h - old)
        }
        this.#learn()
        // Just jumped somewhere in this part: stay on the spot while it settles.
        const pend = this.#pending
        if (pend && Date.now() < pend.until && pend.part === p) this.#scrollToAnchor(pend.part, pend.anchor, pend.reason, true)
    }

    // How tall a byte of text turns out, so unloaded parts are guessed better.
    #learn() {
        let bytes = 0, px = 0
        for (const p of this.#parts) if (p.doc) { bytes += this.sections[p.index]?.size ?? 0; px += p.h }
        if (bytes > 2000) this.#pxPerByte = px / bytes
    }

    #load(p) {
        if (!p) return Promise.resolve()
        if (p.loading) return p.loading
        p.loading = (async () => {
            let src
            try { src = await this.sections[p.index].load() } catch (e) { console.warn(e?.stack ?? e); p.loading = null; return }
            const frame = document.createElement('iframe')
            frame.setAttribute('sandbox', 'allow-same-origin allow-scripts')
            frame.setAttribute('scrolling', 'no')
            await new Promise(resolve => {
                frame.addEventListener('load', resolve, { once: true })
                frame.src = src
                p.box.append(frame)
            })
            const doc = frame.contentDocument
            p.frame = frame
            p.doc = doc
            if (doc.head) {
                const before = doc.createElement('style')
                doc.head.prepend(before)
                const after = doc.createElement('style')
                doc.head.append(after)
                p.$styles = [before, after]
            }
            this.#applyStyles(p)
            this.dispatchEvent(new CustomEvent('load', { detail: { doc, index: p.index } }))
            this.#layoutDoc(p)
            this.dispatchEvent(new CustomEvent('create-overlayer', {
                detail: {
                    doc, index: p.index,
                    attach: o => {
                        p.overlayer = o
                        o.element.style.top = `${-(p.trim ?? 0)}px`
                        p.box.append(o.element)
                    },
                },
            }))
            // Pictures loading change the height too (even when the page's box doesn't).
            doc.addEventListener('load', () => this.#measure(p), true)
            p.ro = new ResizeObserver(() => this.#measure(p))
            if (doc.body) p.ro.observe(doc.body)
            doc.fonts?.ready?.then(() => this.#measure(p))
            this.#measure(p)
        })()
        return p.loading
    }

    #unload(p) {
        if (!p.frame) return
        p.ro?.disconnect()
        p.frame.remove()
        p.overlayer?.element?.remove()
        p.frame = null
        p.doc = null
        p.overlayer = null
        p.loading = null
        this.sections[p.index]?.unload?.()
    }

    // Parts far from the screen are let go (their height is kept).
    #clean() {
        const c = this.#container
        const lo = c.scrollTop - c.clientHeight * 6, hi = c.scrollTop + c.clientHeight * 7
        for (const p of this.#parts) {
            if (!p.frame) continue
            const top = p.el.offsetTop, bottom = top + p.el.offsetHeight
            if (bottom < lo || top > hi) this.#unload(p)
        }
    }

    #applyStyles(p) {
        const s = this.#styles
        if (!p.$styles || s == null) return
        const [before, after] = p.$styles
        if (Array.isArray(s)) { before.textContent = s[0]; after.textContent = s[1] }
        else after.textContent = s
    }

    setStyles(styles) {
        this.#styles = styles
        for (const p of this.#parts) if (p.doc) { this.#applyStyles(p); this.#layoutDoc(p) }
        requestAnimationFrame(() => { for (const p of this.#parts) this.#measure(p) })
    }

    // ---------- where the reader is ----------

    #current() {
        const y = this.#container.scrollTop + 2
        let found = this.#parts[0]
        for (const p of this.#parts) {
            if (p.el.offsetTop <= y) found = p
            else break
        }
        return found
    }

    #onScroll() {
        const now = Date.now()
        clearTimeout(this.#reportTimer)
        if (now - this.#lastReport > 250) this.#report('scroll')
        else this.#reportTimer = setTimeout(() => this.#report('scroll'), 200)
        clearTimeout(this.#cleanTimer)
        this.#cleanTimer = setTimeout(() => this.#clean(), 800)
        // The reader scrolled away from where they jumped to: stop holding it there.
        if (this.#pending && Math.abs(this.#container.scrollTop - this.#expect) > 3) this.#pending = null
    }

    #report(reason) {
        const p = this.#current()
        if (!p) return
        this.#lastReport = Date.now()
        this.#index = p.index
        const c = this.#container
        const boxTop = p.el.offsetTop + p.box.offsetTop
        const y = c.scrollTop - boxTop
        const fraction = Math.max(0, Math.min(1, y / Math.max(1, p.h)))
        const size = Math.min(1, c.clientHeight / Math.max(1, p.h))
        let range = null
        const t = p.trim ?? 0
        try { if (p.doc) range = visibleRange(p.doc, Math.max(0, y) + t, Math.max(0, y) + t + c.clientHeight) } catch { }
        this.dispatchEvent(new CustomEvent('relocate', { detail: { reason, range, index: p.index, fraction, size } }))
    }

    // ---------- going places ----------

    #yFor(p, anchor) {
        const top = p.el.offsetTop + p.box.offsetTop
        if (typeof anchor === 'function') anchor = p.doc ? anchor(p.doc) : 0
        if (anchor == null) return top
        if (typeof anchor === 'number') return top + anchor * p.h
        const rects = anchor.getClientRects?.()
        const rect = rects && ([...rects].find(r => r.width > 0 && r.height > 0) ?? rects[0])
        const t = p.trim ?? 0
        if (rect) return top + rect.top - t
        const r2 = anchor.getBoundingClientRect?.()
        return r2 ? top + r2.top - t : top
    }

    #scrollToAnchor(p, anchor, reason, quiet) {
        let y = this.#yFor(p, anchor)
        if (reason === 'selection') y -= this.#container.clientHeight / 3
        else if (anchor && typeof anchor !== 'number') y -= 24
        this.#setTop(Math.max(0, y))
        if (!quiet) this.#report(reason ?? 'anchor')
    }

    async goTo(target) {
        const t = await target
        if (!t || t.index == null) return
        const p = this.#partFor(t.index)
        if (!p) return
        await this.#load(p)
        const reason = t.select ? 'selection' : 'navigation'
        this.#scrollToAnchor(p, t.anchor, reason)
        this.#pending = { part: p, anchor: t.anchor, reason, until: Date.now() + 2500 }
        // The parts either side, so scrolling on is seamless.
        const i = this.#parts.indexOf(p)
        this.#load(this.#parts[i + 1])
        this.#load(this.#parts[i - 1])
    }
    async scrollToAnchor(anchor, select) {
        const doc = anchor?.startContainer?.ownerDocument ?? anchor?.ownerDocument
        const p = this.#parts.find(x => x.doc && x.doc === doc)
        if (p) this.#scrollToAnchor(p, anchor, select ? 'selection' : 'navigation')
    }

    #setTop(y) {
        const c = this.#container
        c.scrollTop = y
        this.#expect = c.scrollTop
    }

    #by(dy) {
        const c = this.#container
        const before = c.scrollTop
        c.scrollBy({ top: dy, behavior: 'smooth' })
        return Promise.resolve(before === c.scrollTop && ((dy > 0 && this.atEnd) || (dy < 0 && this.atStart)))
    }
    next(distance) { return this.#by(distance ?? this.#container.clientHeight * 0.9) }
    prev(distance) { return this.#by(-(distance ?? this.#container.clientHeight * 0.9)) }
    /** Sable: a smooth scroll by so many pixels (arrow keys). */
    scrollByPx(dy) { this.#container.scrollBy({ top: dy, behavior: 'smooth' }) }
    /** Sable: an instant scroll (returns how far it went). */
    freeScroll(dy) {
        const c = this.#container
        const before = c.scrollTop
        c.scrollTop += dy
        return c.scrollTop - before
    }
    get scrollEdge() {
        const c = this.#container
        if (c.scrollHeight <= c.clientHeight + 1) return 2
        if (c.scrollTop <= 1) return -1
        if (c.scrollTop >= c.scrollHeight - c.clientHeight - 1) return 1
        return 0
    }

    get continuous() { return true }
    get scrolled() { return true }
    get size() { return this.#container.clientHeight }
    get viewSize() { return this.#container.scrollHeight }
    get start() { return this.#container.scrollTop }
    get end() { return this.#container.scrollTop + this.#container.clientHeight }
    get atStart() { return this.#container.scrollTop <= 1 }
    get atEnd() { const c = this.#container; return c.scrollTop >= c.scrollHeight - c.clientHeight - 1 }
    // Screens through the current chapter (for "4 of 12" at the bottom).
    get pages() { const p = this.#current(); return p ? Math.max(1, Math.round(p.h / Math.max(1, this.size))) : 1 }
    get page() {
        const p = this.#current()
        if (!p) return 0
        const y = this.#container.scrollTop - (p.el.offsetTop + p.box.offsetTop)
        return Math.max(0, Math.min(this.pages - 1, Math.floor(y / Math.max(1, this.size))))
    }

    getContents() {
        const cur = this.#index
        return this.#parts.filter(p => p.doc)
            .sort((a, b) => (a.index === cur ? -1 : b.index === cur ? 1 : Math.abs(a.index - cur) - Math.abs(b.index - cur)))
            .map(p => ({ index: p.index, doc: p.doc, overlayer: p.overlayer }))
    }
    focusView() { this.#byIndex.get(this.#index)?.frame?.contentWindow?.focus() }
    destroy() {
        this.#io.disconnect()
        this.#ro.disconnect()
        for (const p of this.#parts) this.#unload(p)
    }
}

customElements.define('sable-scroller', Scroller)

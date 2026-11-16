// Sable's bridge between the app and the foliate-js book engine.
// The app talks to this page with window.sable.*; this page reports back
// to the app by posting events to the local server.
import './view.js'

const params = new URLSearchParams(location.search)
const token = params.get('t')
const base = location.pathname.split('/reader/')[0]
const $ = s => document.querySelector(s)

const post = (type, data = {}) =>
    fetch(`${base}/event/${token}`, { method: 'POST', body: JSON.stringify({ type, ...data }) }).catch(() => {})

window.addEventListener('error', e => { if (!String(e.message).includes('ResizeObserver')) post('error', { message: `${e.message} (${e.filename}:${e.lineno})` }) })
window.addEventListener('unhandledrejection', e => post('error', { message: String(e.reason?.stack ?? e.reason) }))

let view, style = {}, theme = {}, lastDetail = null, pageNo = 0

const fontStack = f => ({
    Literata: "'Literata', Georgia, serif",
    Inter: "'Inter', 'Segoe UI', system-ui, sans-serif",
    Georgia: "Georgia, 'Times New Roman', serif",
    'Palatino Linotype': "'Palatino Linotype', Palatino, 'Book Antiqua', serif",
}[f] ?? null)

const fontFaces = () => `
@font-face { font-family: 'Literata'; font-style: normal; font-weight: 200 900; src: url('${location.origin}${base}/fonts/Literata.woff2') format('woff2'); }
@font-face { font-family: 'Literata'; font-style: italic; font-weight: 200 900; src: url('${location.origin}${base}/fonts/Literata-Italic.woff2') format('woff2'); }
@font-face { font-family: 'Inter'; font-weight: 400; src: url('${location.origin}${base}/fonts/Inter-Regular.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 600; src: url('${location.origin}${base}/fonts/Inter-SemiBold.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 700; src: url('${location.origin}${base}/fonts/Inter-Bold.ttf') format('truetype'); }
`

const bookCSS = () => {
    const fam = fontStack(style.font)
    const own = style.publisherStyles
    return `
@namespace epub "http://www.idpf.org/2007/ops";
${fontFaces()}
html { color-scheme: dark; color: ${theme.fg} !important; background: transparent !important; }
html, body { font-size: ${style.size}px !important; }
body * { color: inherit !important; background-color: transparent !important; border-color: ${theme.muted} !important; }
a:link, a:visited { color: ${theme.link} !important; }
${fam && !own ? `body, body p, body div, body span, body li, body blockquote, body dd, body h1, body h2, body h3, body h4, body h5, body h6, body td { font-family: ${fam} !important; }` : ''}
${own ? '' : `
p, li, blockquote, dd, div {
    line-height: ${style.spacing} !important;
    text-align: ${style.justify ? 'justify' : 'start'} !important;
    -webkit-hyphens: auto; hyphens: auto;
    widows: 2; orphans: 2;
}
p { margin-top: 0 !important; margin-bottom: ${(style.spacing - 1) * 0.9 + 0.35}em !important; }
[align="center"], .center, .centered { text-align: center !important; }
h1, h2, h3, h4 { line-height: 1.3 !important; text-align: center; }`}
img, svg, image { cursor: zoom-in; }
img.sable-fit {
    display: block !important;
    height: var(--sable-page-h) !important; width: auto !important;
    max-height: var(--sable-page-h) !important; max-width: 100% !important;
    object-fit: contain !important; margin: 0 auto !important; padding: 0 !important;
    break-inside: avoid; page-break-inside: avoid;
}
.sable-fit-holder { text-indent: 0 !important; margin: 0 !important; padding: 0 !important; line-height: 0 !important; text-align: center !important; }
pre { white-space: pre-wrap !important; }
aside[epub|type~="footnote"], aside[epub|type~="endnote"], aside[epub|type~="note"], aside[epub|type~="rearnote"] { display: none; }
::selection { background: ${theme.accent}55; }
`
}

const applyTheme = () => {
    const r = document.documentElement.style
    r.setProperty('--bg', theme.bg)
    r.setProperty('--fg', theme.fg)
    r.setProperty('--muted', theme.muted)
}

const columns = () => {
    const w = window.innerWidth
    if (style.layout === 'one') return 1
    if (style.layout === 'two') return 2
    return w >= 1000 ? 2 : 1
}

const applyLayout = () => {
    if (!view?.renderer) return
    const r = view.renderer
    // Scrolling is one column down the middle of the window.
    const cols = style.flow === 'scrolled' ? 1 : columns()
    const w = window.innerWidth
    r.setAttribute('flow', style.flow === 'scrolled' ? 'scrolled' : 'paginated')
    r.setAttribute('max-column-count', String(cols))
    r.setAttribute('max-inline-size', cols === 2 ? `${Math.max(320, Math.floor(w / 2))}px` : `${Math.max(420, Math.min(780, w))}px`)
    const gap = Math.max(2, Math.min(30, (style.margin * 2) / w * 100 * (cols === 2 ? 1 : 1)))
    r.setAttribute('gap', `${gap.toFixed(1)}%`)
    r.setAttribute('margin', '44px')
    if (style.animate) r.setAttribute('animated', '')
    else r.removeAttribute('animated')
}

const applyStyle = () => {
    refitImages()
    applyLayout()
    view?.renderer?.setStyles?.(bookCSS())
}

// ---------- clicks, keys and the wheel ----------

const isInteractive = el => el?.closest?.('a[href], button, input, textarea, select, audio, video')

const onDocClick = e => {
    const doc = e.target?.ownerDocument
    if (isInteractive(e.target)) return
    const sel = doc?.getSelection?.()
    if (sel && !sel.isCollapsed) return
    if (e.target?.closest?.('img, svg, image')) {
        const img = e.target.closest('img') ?? e.target.closest('image')
        const src = pictureSrc(img)
        if (src) { openLightbox(src, img); return }
    }
    const frame = doc?.defaultView?.frameElement
    const left = frame ? frame.getBoundingClientRect().left : 0
    const x = (left + e.clientX) / window.innerWidth
    zone(x)
}

const zone = x => {
    if (x < 0.3) view.goLeft()
    else if (x > 0.7) view.goRight()
    else post('tap')
    post('activity')
}

const pageKeys = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', ' ', 'Home', 'End'])

const onKey = e => {
    if ($('#lightbox').classList.contains('show')) {
        if (e.key === 'Escape') closeLightbox()
        else if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'PageDown' || e.key === ' ') stepPicture(1)
        else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'PageUp') stepPicture(-1)
        e.preventDefault()
        return
    }
    const tag = e.target?.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA') return
    if (style.flow === 'scrolled' && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) smoothScroll(e.key === 'ArrowDown' ? 100 : -100)
    else if (e.key === 'ArrowLeft') view.goLeft()
    else if (e.key === 'ArrowRight') view.goRight()
    else if (e.key === 'PageUp') view.prev()
    else if (e.key === 'PageDown' || e.key === ' ') view.next()
    else if (e.key === 'Home') goChapterEdge(false)
    else if (e.key === 'End') goChapterEdge(true)
    if (pageKeys.has(e.key)) e.preventDefault()
    post('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey })
}

// The mouse wheel: in page mode, one page per notch (small trackpad moves add up
// first); in scroll mode, a smooth eased scroll of a set distance per notch.
let wheelAcc = 0, wheelLock = 0
let scrollTarget = 0, scrollAnim = 0
const onWheel = e => {
    if ($('#lightbox').classList.contains('show') || e.ctrlKey) return
    const dy = e.deltaMode === 1 ? e.deltaY * 40 : e.deltaMode === 2 ? e.deltaY * window.innerHeight : e.deltaY
    const dx = e.deltaMode === 1 ? e.deltaX * 40 : e.deltaX
    const d = Math.abs(dy) >= Math.abs(dx) ? dy : dx
    if (!d) return
    e.preventDefault()
    post('activity')
    if (style.flow === 'scrolled') return smoothScroll(d)
    const now = Date.now()
    if (now < wheelLock) return
    wheelAcc += d
    if (Math.abs(wheelAcc) >= 50) {
        wheelAcc > 0 ? view.next() : view.prev()
        wheelAcc = 0
        wheelLock = now + 280
    }
}

const smoothScroll = d => {
    const r = view?.renderer
    if (!r) return
    // A notch (about 100) moves the chosen distance; trackpads move in proportion.
    scrollTarget += d * (style.scrollStep ?? 140) / 100
    if (scrollAnim) return
    let last = 0
    const tick = now => {
        const dt = last ? Math.max(4, Math.min(48, now - last)) : 16
        last = now
        if (Math.abs(scrollTarget) < 0.5) { scrollAnim = 0; scrollTarget = 0; return }
        const move = scrollTarget * Math.min(1, dt / 90)
        const down = move > 0
        // At the top or bottom of this part of the book: go on to the next or previous one.
        if (down ? r.viewSize - r.end <= 2 : r.start <= 0) {
            scrollTarget = 0
            scrollAnim = 0
            down ? view.next() : view.prev()
            return
        }
        r.scrollBy(move, move)
        scrollTarget -= move
        scrollAnim = requestAnimationFrame(tick)
    }
    scrollAnim = requestAnimationFrame(tick)
}

// Mouse back and forward buttons: the app decides what they do.
const onMouseButton = e => {
    if (e.button !== 3 && e.button !== 4) return
    e.preventDefault()
    if ($('#lightbox').classList.contains('show')) { stepPicture(e.button === 4 ? 1 : -1); return }
    post('mouse', { button: e.button === 3 ? 'back' : 'forward' })
}

// Pictures: big ones (illustrations) fill the page: the window in one-page view,
// half of it in two-page view. Small ones (icons, gaiji) stay as they are.
const pageHeight = () => Math.max(200, window.innerHeight - (style.flow === 'scrolled' ? 24 : 88))
const fitImages = doc => {
    doc.documentElement.style.setProperty('--sable-page-h', `${pageHeight()}px`)
    const mark = img => {
        const big = img.naturalWidth >= 400 || img.naturalHeight >= 400
        if (!big) return
        img.classList.add('sable-fit')
        const p = img.parentElement
        if (p && p !== doc.body && p.textContent.trim() === '') p.classList.add('sable-fit-holder')
    }
    for (const img of doc.querySelectorAll('img')) {
        if (img.complete) mark(img)
        else img.addEventListener('load', () => mark(img), { once: true })
    }
}
const refitImages = () => {
    for (const c of view?.renderer?.getContents?.() ?? []) c.doc?.documentElement.style.setProperty('--sable-page-h', `${pageHeight()}px`)
}

const goChapterEdge = end => {
    const d = lastDetail
    if (!d) return
    const idx = view.renderer?.getContents?.()?.[0]?.index
    if (idx == null) return
    view.renderer.goTo({ index: idx, anchor: end ? 1 : 0 })
}

// ---------- pictures ----------

let lb = { scale: 1, x: 0, y: 0, drag: null }
let pictures = [], pictureAt = -1, stepping = false
const lbImg = () => $('#lightbox img')
const lbApply = () => {
    const im = lbImg()
    im.style.transform = `translate(${lb.x}px, ${lb.y}px) scale(${lb.scale})`
}
const pictureSrc = el => el?.src || el?.getAttribute?.('href') || el?.getAttributeNS?.('http://www.w3.org/1999/xlink', 'href') || ''
const isBigPicture = el => el.tagName.toLowerCase() === 'image' || el.naturalWidth >= 200 || el.naturalHeight >= 200
const picturesInView = () => {
    const out = []
    for (const c of view?.renderer?.getContents?.() ?? [])
        for (const el of c.doc?.querySelectorAll('img, image') ?? [])
            if (isBigPicture(el) && pictureSrc(el)) out.push({ el, index: c.index })
    return out
}
const showPicture = src => {
    const im = lbImg()
    im.onload = () => {
        const fit = Math.min(window.innerWidth * 0.96 / im.naturalWidth, window.innerHeight * 0.96 / im.naturalHeight)
        lb = { scale: fit, x: -im.naturalWidth * fit / 2, y: -im.naturalHeight * fit / 2, drag: null }
        lbApply()
    }
    im.src = src
}
const openLightbox = (src, el) => {
    pictures = picturesInView()
    pictureAt = Math.max(0, pictures.findIndex(p => p.el === el))
    showPicture(src)
    $('#lightbox').classList.add('show')
    post('lightbox', { open: true })
}
const closeLightbox = () => {
    $('#lightbox').classList.remove('show')
    post('lightbox', { open: false })
}

// The next or previous picture. Past the ones in this part of the book, the book
// moves on to the next part that has a picture, so the page follows along.
const stepPicture = async dir => {
    if (stepping) return
    pictures = picturesInView()
    const next = pictureAt + dir
    if (next >= 0 && next < pictures.length) {
        pictureAt = next
        showPicture(pictureSrc(pictures[next].el))
        return
    }
    const sections = view.book.sections
    const here = view.renderer.getContents()?.[0]?.index ?? 0
    stepping = true
    try {
        for (let i = here + dir; i >= 0 && i < sections.length; i += dir) {
            const s = sections[i]
            if (s.linear === 'no' || !s.createDocument) continue
            let doc
            try { doc = await s.createDocument() } catch { continue }
            if (!doc?.querySelector('img, image')) continue
            await view.goTo(i)
            for (let t = 0; t < 20; t++) {
                await new Promise(r => setTimeout(r, 100))
                pictures = picturesInView()
                if (pictures.length && pictures.every(p => p.el.tagName.toLowerCase() === 'image' || p.el.complete)) break
            }
            if (!pictures.length) continue
            pictureAt = dir > 0 ? 0 : pictures.length - 1
            showPicture(pictureSrc(pictures[pictureAt].el))
            return
        }
    } finally { stepping = false }
}

$('#lightbox').addEventListener('click', e => { if (e.target.id === 'lightbox' || e.target.classList.contains('hint')) closeLightbox() })
$('#lightbox').addEventListener('wheel', e => {
    e.preventDefault()
    e.stopPropagation()
    const f = e.deltaY < 0 ? 1.15 : 1 / 1.15
    const cx = e.clientX - window.innerWidth / 2, cy = e.clientY - window.innerHeight / 2
    lb.x = cx - (cx - lb.x) * f
    lb.y = cy - (cy - lb.y) * f
    lb.scale *= f
    lbApply()
}, { passive: false })
lbImg().addEventListener('mousedown', e => { if (e.button !== 0) return; e.preventDefault(); lb.drag = { x: e.clientX - lb.x, y: e.clientY - lb.y, moved: false } })
window.addEventListener('mousemove', e => {
    if (!lb.drag) return
    lb.drag.moved = true
    lb.x = e.clientX - lb.drag.x
    lb.y = e.clientY - lb.drag.y
    lbApply()
})
window.addEventListener('mouseup', () => { setTimeout(() => lb.drag = null, 0) })
lbImg().addEventListener('click', e => { e.stopPropagation() })

// ---------- reporting where the reader is ----------

let lastSent = ''
const onRelocate = ({ detail }) => {
    lastDetail = detail
    const r = view.renderer
    let page = 0, pages = 0
    if (r && typeof r.page === 'number') {
        if (r.scrolled) {
            page = Math.min(r.pages, r.page + 1)
            pages = Math.max(1, r.pages)
        } else {
            page = Math.max(1, r.page)
            pages = Math.max(1, r.pages - 2)
        }
    }
    let fraction = detail.fraction
    if (!Number.isFinite(fraction)) {
        const l = detail.location
        fraction = l && l.total ? l.current / l.total : 0
    }
    pageNo = page
    const sig = `${detail.cfi}|${page}|${pages}`
    if (sig === lastSent) return
    lastSent = sig
    post('relocate', {
        fraction,
        cfi: detail.cfi ?? '',
        location: detail.location ?? null,
        time: detail.time ?? null,
        chapter: detail.tocItem?.label ?? '',
        chapterHref: detail.tocItem?.href ?? '',
        page, pages,
        // The end of the book: the end of the last section (or nearly all the way through).
        atEnd: !!r?.atEnd && ((detail.section && detail.section.current >= detail.section.total - 1) || fraction >= 0.985),
    })
}

const onLoad = ({ detail: { doc } }) => {
    doc.addEventListener('click', onDocClick)
    doc.addEventListener('keydown', onKey)
    doc.addEventListener('wheel', onWheel, { passive: false })
    doc.addEventListener('mouseup', onMouseButton)
    doc.addEventListener('auxclick', e => { if (e.button === 3 || e.button === 4) e.preventDefault() })
    fitImages(doc)
}

const flattenToc = (items, level = 0, out = []) => {
    for (const it of items ?? []) {
        out.push({ label: (it.label ?? '').trim(), href: it.href ?? '', level })
        if (it.subitems?.length) flattenToc(it.subitems, level + 1, out)
    }
    return out
}

// ---------- commands from the app ----------

let searchRun = 0
window.sable = {
    next: () => view?.next(),
    prev: () => view?.prev(),
    left: () => view?.goLeft(),
    right: () => view?.goRight(),
    goTo: target => view?.goTo(target).catch(e => post('error', { message: String(e) })),
    goToFraction: f => view?.goToFraction(f),
    chapterStart: () => goChapterEdge(false),
    chapterEnd: () => goChapterEdge(true),
    setStyle: s => { style = { ...style, ...s }; applyStyle() },
    setTheme: t => { theme = { ...theme, ...t }; applyTheme(); applyStyle() },
    closeLightbox,
    async search(q) {
        const run = ++searchRun
        view.clearSearch()
        if (!q) { post('search', { results: [], done: true }); return }
        const results = []
        for await (const r of view.search({ query: q })) {
            if (run !== searchRun) return
            if (r === 'done') break
            if (r.subitems) {
                for (const s of r.subitems) {
                    results.push({ cfi: s.cfi, label: r.label ?? '', pre: s.excerpt?.pre ?? '', match: s.excerpt?.match ?? '', post: s.excerpt?.post ?? '' })
                }
            } else if (r.cfi) {
                results.push({ cfi: r.cfi, label: r.label ?? '', pre: r.excerpt?.pre ?? '', match: r.excerpt?.match ?? '', post: r.excerpt?.post ?? '' })
            }
            if (results.length >= 300) break
        }
        if (run === searchRun) post('search', { results, done: true })
    },
    clearSearch: () => { searchRun++; view?.clearSearch() },
}

window.addEventListener('keydown', onKey)
window.addEventListener('wheel', onWheel, { passive: false })
window.addEventListener('mouseup', e => onMouseButton(e))
window.addEventListener('auxclick', e => { if (e.button === 3 || e.button === 4) e.preventDefault() })
let resizeTimer
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { refitImages(); applyLayout() }, 120) })

// ---------- start ----------

const main = async () => {
    const init = await (await fetch(`${base}/init/${token}`)).json()
    style = init.style
    theme = init.theme
    applyTheme()
    const blob = await (await fetch(`${base}/book/${token}`)).blob()
    const file = new File([blob], init.fileName)
    view = document.createElement('foliate-view')
    view.addEventListener('relocate', onRelocate)
    view.addEventListener('load', onLoad)
    document.body.append(view)
    await view.open(file)
    $('#message')?.remove()
    applyStyle()
    const book = view.book
    post('ready', {
        toc: flattenToc(book.toc),
        sections: view.getSectionFractions?.() ?? [],
        title: typeof book.metadata?.title === 'string' ? book.metadata.title : '',
        fixed: !!view.isFixedLayout,
    })
    await view.init({ lastLocation: init.position || null, showTextStart: !init.position })
}

main().catch(e => {
    const m = $('#message')
    if (m) m.textContent = 'This book couldn’t be opened.'
    post('failed', { message: String(e?.stack ?? e) })
})

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

window.addEventListener('error', e => post('error', { message: `${e.message} (${e.filename}:${e.lineno})` }))
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
    const cols = columns()
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
        const src = img?.src ?? img?.getAttribute?.('href') ?? img?.getAttributeNS?.('http://www.w3.org/1999/xlink', 'href')
        if (src) { openLightbox(src); return }
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

const pageKeys = new Set(['ArrowLeft', 'ArrowRight', 'PageUp', 'PageDown', ' ', 'Home', 'End'])

const onKey = e => {
    if ($('#lightbox').classList.contains('show')) {
        if (e.key === 'Escape') closeLightbox()
        e.preventDefault()
        return
    }
    const tag = e.target?.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA') return
    if (e.key === 'ArrowLeft') view.goLeft()
    else if (e.key === 'ArrowRight') view.goRight()
    else if (e.key === 'PageUp') view.prev()
    else if (e.key === 'PageDown' || e.key === ' ') view.next()
    else if (e.key === 'Home') goChapterEdge(false)
    else if (e.key === 'End') goChapterEdge(true)
    if (pageKeys.has(e.key)) e.preventDefault()
    post('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey })
}

let wheelLock = 0
const onWheel = e => {
    if (style.flow === 'scrolled' || $('#lightbox').classList.contains('show')) return
    if (e.ctrlKey) return
    const now = Date.now()
    if (now - wheelLock < 250) return
    wheelLock = now
    if (e.deltaY > 0 || e.deltaX > 0) view.next()
    else view.prev()
    post('activity')
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
const lbImg = () => $('#lightbox img')
const lbApply = () => {
    const im = lbImg()
    im.style.transform = `translate(${lb.x}px, ${lb.y}px) scale(${lb.scale})`
}
const openLightbox = src => {
    const im = lbImg()
    im.onload = () => {
        const fit = Math.min(window.innerWidth * 0.96 / im.naturalWidth, window.innerHeight * 0.96 / im.naturalHeight, 1.5)
        lb = { scale: fit, x: -im.naturalWidth * fit / 2, y: -im.naturalHeight * fit / 2, drag: null }
        lbApply()
    }
    im.src = src
    $('#lightbox').classList.add('show')
    post('lightbox', { open: true })
}
const closeLightbox = () => {
    $('#lightbox').classList.remove('show')
    post('lightbox', { open: false })
}
$('#lightbox').addEventListener('click', e => { if (e.target.id === 'lightbox') closeLightbox() })
$('#lightbox').addEventListener('wheel', e => {
    e.preventDefault()
    const f = e.deltaY < 0 ? 1.15 : 1 / 1.15
    const cx = e.clientX - window.innerWidth / 2, cy = e.clientY - window.innerHeight / 2
    lb.x = cx - (cx - lb.x) * f
    lb.y = cy - (cy - lb.y) * f
    lb.scale *= f
    lbApply()
}, { passive: false })
lbImg().addEventListener('mousedown', e => { e.preventDefault(); lb.drag = { x: e.clientX - lb.x, y: e.clientY - lb.y, moved: false } })
window.addEventListener('mousemove', e => {
    if (!lb.drag) return
    lb.drag.moved = true
    lb.x = e.clientX - lb.drag.x
    lb.y = e.clientY - lb.drag.y
    lbApply()
})
window.addEventListener('mouseup', () => { setTimeout(() => lb.drag = null, 0) })
lbImg().addEventListener('click', e => { if (!lb.drag?.moved) closeLightbox(); e.stopPropagation() })

// ---------- reporting where the reader is ----------

let lastSent = ''
const onRelocate = ({ detail }) => {
    lastDetail = detail
    const r = view.renderer
    let page = 0, pages = 0
    if (r && typeof r.page === 'number') {
        page = r.page
        pages = Math.max(1, r.pages - 2)
    }
    pageNo = page
    const sig = `${detail.cfi}|${page}|${pages}`
    if (sig === lastSent) return
    lastSent = sig
    post('relocate', {
        fraction: detail.fraction ?? 0,
        cfi: detail.cfi ?? '',
        location: detail.location ?? null,
        time: detail.time ?? null,
        chapter: detail.tocItem?.label ?? '',
        chapterHref: detail.tocItem?.href ?? '',
        page, pages,
        // The end of the book: the end of the last section (or nearly all the way through).
        atEnd: !!r?.atEnd && ((detail.section && detail.section.current >= detail.section.total - 1) || (detail.fraction ?? 0) >= 0.985),
    })
}

const onLoad = ({ detail: { doc } }) => {
    doc.addEventListener('click', onDocClick)
    doc.addEventListener('keydown', onKey)
    doc.addEventListener('wheel', onWheel, { passive: true })
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
window.addEventListener('wheel', onWheel, { passive: true })
let resizeTimer
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(applyLayout, 120) })

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

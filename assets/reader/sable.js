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
    // Segoe UI is Windows' own font (other systems use their nearest sans).
    'Segoe UI': "'Segoe UI', 'Open Sans', system-ui, sans-serif",
    'Open Sans': "'Open Sans', 'Segoe UI', sans-serif",
    'PT Serif': "'PT Serif', Georgia, serif",
    Domine: "'Domine', Georgia, serif",
    Lato: "'Lato', 'Segoe UI', sans-serif",
    'Arbutus Slab': "'Arbutus Slab', Georgia, serif",
}[f] ?? null)

// Bundled fonts (all under the SIL Open Font License): [family, file, style, weight].
const bundled = [
 [
  "Literata",
  "Literata.woff2",
  "normal",
  "200 900",
  ""
 ],
 [
  "Literata",
  "Literata-Italic.woff2",
  "italic",
  "200 900",
  ""
 ],
 [
  "Open Sans",
  "open-sans-latin-ext-wght-normal.woff2",
  "normal",
  "300 800",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Open Sans",
  "open-sans-latin-wght-normal.woff2",
  "normal",
  "300 800",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "PT Serif",
  "pt-serif-latin-ext-400-normal.woff2",
  "normal",
  "400",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "PT Serif",
  "pt-serif-latin-400-normal.woff2",
  "normal",
  "400",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "PT Serif",
  "pt-serif-latin-ext-700-italic.woff2",
  "italic",
  "700",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "PT Serif",
  "pt-serif-latin-700-italic.woff2",
  "italic",
  "700",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "PT Serif",
  "pt-serif-latin-ext-400-italic.woff2",
  "italic",
  "400",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "PT Serif",
  "pt-serif-latin-400-italic.woff2",
  "italic",
  "400",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "PT Serif",
  "pt-serif-latin-ext-700-normal.woff2",
  "normal",
  "700",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "PT Serif",
  "pt-serif-latin-700-normal.woff2",
  "normal",
  "700",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Domine",
  "domine-latin-ext-wght-normal.woff2",
  "normal",
  "400 700",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Domine",
  "domine-latin-wght-normal.woff2",
  "normal",
  "400 700",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Lato",
  "lato-latin-ext-400-normal.woff2",
  "normal",
  "400",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Lato",
  "lato-latin-400-normal.woff2",
  "normal",
  "400",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Lato",
  "lato-latin-ext-700-italic.woff2",
  "italic",
  "700",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Lato",
  "lato-latin-700-italic.woff2",
  "italic",
  "700",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Lato",
  "lato-latin-ext-400-italic.woff2",
  "italic",
  "400",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Lato",
  "lato-latin-400-italic.woff2",
  "italic",
  "400",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Lato",
  "lato-latin-ext-700-normal.woff2",
  "normal",
  "700",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Lato",
  "lato-latin-700-normal.woff2",
  "normal",
  "700",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Arbutus Slab",
  "arbutus-slab-latin-ext-400-normal.woff2",
  "normal",
  "400",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Arbutus Slab",
  "arbutus-slab-latin-400-normal.woff2",
  "normal",
  "400",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ],
 [
  "Open Sans",
  "open-sans-latin-ext-wght-italic.woff2",
  "italic",
  "300 800",
  "U+0100-02BA,U+02BD-02C5,U+02C7-02CC,U+02CE-02D7,U+02DD-02FF,U+0304,U+0308,U+0329,U+1D00-1DBF,U+1E00-1E9F,U+1EF2-1EFF,U+2020,U+20A0-20AB,U+20AD-20C0,U+2113,U+2C60-2C7F,U+A720-A7FF"
 ],
 [
  "Open Sans",
  "open-sans-latin-wght-italic.woff2",
  "italic",
  "300 800",
  "U+0000-00FF,U+0131,U+0152-0153,U+02BB-02BC,U+02C6,U+02DA,U+02DC,U+0304,U+0308,U+0329,U+2000-206F,U+20AC,U+2122,U+2191,U+2193,U+2212,U+2215,U+FEFF,U+FFFD"
 ]
]
const fontFaces = () => bundled.map(([fam, file, st, wt, range]) =>
    `@font-face { font-family: '${fam}'; font-style: ${st}; font-weight: ${wt}; font-display: block; src: url('${location.origin}${base}/fonts/${file}') format('woff2');${range ? ` unicode-range: ${range};` : ''} }`).join('\n') + `
@font-face { font-family: 'Inter'; font-weight: 400; src: url('${location.origin}${base}/fonts/Inter-Regular.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 600; src: url('${location.origin}${base}/fonts/Inter-SemiBold.ttf') format('truetype'); }
@font-face { font-family: 'Inter'; font-weight: 700; src: url('${location.origin}${base}/fonts/Inter-Bold.ttf') format('truetype'); }
`

// The text controls, with their defaults (for settings saved by older versions).
const num = (v, d) => (typeof v === 'number' && isFinite(v) ? v : d)
const alignOf = () => ({ left: 'left', center: 'center', right: 'right', justify: 'justify' }[style.align] ?? (style.justify === false ? 'left' : 'justify'))

const bookCSS = () => {
    const fam = fontStack(style.font)
    const own = style.publisherStyles
    const fg = style.textColor || theme.fg
    return `/*sable*/
@namespace epub "http://www.idpf.org/2007/ops";
${fontFaces()}
html { color-scheme: dark; color: ${fg} !important; background: transparent !important; }
html, body { font-size: ${style.size}px !important; }
${num(style.wordSpacing, 0) ? `body * { word-spacing: ${num(style.wordSpacing, 0)}px !important; }` : ''}
body * { color: inherit !important; background-color: transparent !important; border-color: ${theme.muted} !important; }
a:link, a:visited { color: ${theme.link} !important; }
${fam && !own ? `body, body p, body div, body span, body li, body blockquote, body dd, body h1, body h2, body h3, body h4, body h5, body h6, body td { font-family: ${fam} !important; }` : ''}
${own ? '' : `
p, li, blockquote, dd, div {
    line-height: ${style.spacing} !important;
    text-align: ${alignOf()} !important;
    -webkit-hyphens: auto; hyphens: auto;
    widows: 2; orphans: 2;
}
p { margin-top: 0 !important; margin-bottom: ${num(style.paraSpacing, 0.5)}em !important; }
${style.indent ? 'p { text-indent: 1.5em !important; } p.sable-first, h1 + p, h2 + p, h3 + p, h4 + p, hr + p { text-indent: 0 !important; }' : ''}
[align="center"], .center, .centered { text-align: center !important; }
h1, h2, h3, h4 { line-height: 1.3 !important; text-align: center; }`}
${style.alignTop ? `
/* Every page starts on the same line: nothing pushes the first line down. */
body, body * { margin-top: 0 !important; padding-top: 0 !important; }
html, body { margin-top: 0 !important; padding-top: 0 !important; }
h1, h2, h3, h4, h5, h6 { margin-bottom: 0.6em !important; }
.sable-empty { display: none !important; }` : ''}
html.sable-restyle * { outline-color: transparent; }
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
${scrollPad[0] || scrollPad[1] ? `html body { padding-top: ${scrollPad[0]}px !important; padding-bottom: ${scrollPad[1]}px !important; }` : ''}
`
}

const applyTheme = () => {
    const r = document.documentElement.style
    r.setProperty('--bg', theme.bg)
    r.setProperty('--fg', theme.fg)
    r.setProperty('--muted', theme.muted)
    drawStars()
}

// Starlight's sky behind the page (the same stars as the app, Ginkgo's
// "Deep space"): a few tinted, a few bigger with a halo.
const drawStars = () => {
    const c = document.getElementById('stars')
    if (!c) return
    const amount = parseFloat(theme.stars ?? '0') || 0
    if (amount <= 0) { c.style.display = 'none'; return }
    const dpr = window.devicePixelRatio || 1
    const w = window.innerWidth, h = window.innerHeight
    c.width = Math.round(w * dpr)
    c.height = Math.round(h * dpr)
    c.style.display = 'block'
    const g = c.getContext('2d')
    g.setTransform(dpr, 0, 0, dpr, 0, 0)
    g.clearRect(0, 0, w, h)
    let seed = 7
    const rnd = () => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 }
    const n = Math.max(10, Math.min(16000, Math.round(w * h / 820 * 0.45 * amount)))
    const cols = ['255,255,255', '190,180,255', '160,255,235', '255,226,184']
    for (let i = 0; i < n; i++) {
        const x = rnd() * w, y = rnd() * h
        const big = rnd() > 0.965
        const r = big ? 1 + rnd() * 0.7 : 0.3 + rnd() * 0.5
        const k = rnd()
        const col = k > 0.88 ? cols[1] : k > 0.8 ? cols[2] : k > 0.74 ? cols[3] : cols[0]
        const a = (0.35 + rnd() * 0.6) * 0.9
        g.fillStyle = `rgba(${col},${a})`
        g.beginPath(); g.arc(x, y, r, 0, Math.PI * 2); g.fill()
        if (big && rnd() > 0.5) {
            g.fillStyle = `rgba(${col},0.11)`
            g.beginPath(); g.arc(x, y, r * 3, 0, Math.PI * 2); g.fill()
        }
    }
}
let starsTimer = 0
addEventListener('resize', () => { clearTimeout(starsTimer); starsTimer = setTimeout(drawStars, 150) })

const columns = () => {
    const w = window.innerWidth
    if (style.layout === 'one') return 1
    if (style.layout === 'two') return 2
    return w >= 1000 ? 2 : 1
}

let scrollPad = [0, 0], inStyle = false
const applyLayout = () => {
    if (!view?.renderer) return
    const r = view.renderer
    // Scrolling is one column down the middle of the window.
    const cols = style.flow === 'scrolled' ? 1 : columns()
    const w = window.innerWidth
    r.setAttribute('flow', style.flow === 'scrolled' ? 'scrolled' : 'paginated')
    r.setAttribute('max-column-count', String(cols))
    // One page (or scrolling) takes the chosen share of the window.
    const pw = Math.max(20, Math.min(100, num(style.pageWidth, 100)))
    r.setAttribute('max-inline-size', cols === 2 ? `${Math.max(320, Math.floor(w / 2))}px` : `${Math.max(320, Math.round(w * pw / 100))}px`)
    // Margins are a share of the window: left and right (also the gap between
    // two pages), and top and bottom. Each page keeps at least ~260px of text.
    const h = window.innerHeight
    const mx = num(style.marginXPct, style.marginX ? style.marginX / 14 : 6)
    const my = num(style.marginYPct, style.marginY ? style.marginY / 8.5 : 5)
    const most = Math.max(0.5, ((w - 260 * cols) / (w * (cols + 1))) * 100)
    const gap = Math.max(0, Math.min(40, most, mx))
    r.setAttribute('gap', `${gap.toFixed(2)}%`)
    const myPx = Math.round(h * Math.min(30, Math.max(0, my)) / 100)
    // Space the app keeps clear (a phone's camera notch, the status line).
    const top = Math.max(0, num(style.insetTop, 0)), bottom = Math.max(0, num(style.insetBottom, 0))
    const scrolled = style.flow === 'scrolled'
    // Scrolling has no pages, so the top and bottom margins move the view itself in.
    view.style.position = 'absolute'
    view.style.left = '0'
    view.style.right = '0'
    view.style.width = 'auto'
    view.style.height = 'auto'
    view.style.top = `${top + (scrolled && style.scrollTop !== false ? myPx : 0)}px`
    view.style.bottom = `${bottom + (scrolled && style.scrollBottom !== false ? myPx : 0)}px`
    r.setAttribute('margin', `${scrolled ? 0 : myPx}px`)
    // Margins switched off while scrolling still show at the start and end of a chapter.
    const pad = [scrolled && style.scrollTop === false ? myPx : 0, scrolled && style.scrollBottom === false ? myPx : 0]
    if (pad[0] !== scrollPad[0] || pad[1] !== scrollPad[1]) {
        scrollPad = pad
        if (!inStyle) r.setStyles?.(bookCSS())
    }
    if (style.animate) r.setAttribute('animated', '')
    else r.removeAttribute('animated')
}

const applyStyle = () => {
    if (view?.renderer && !remaking && (style.flow === 'scrolled') !== viewScrolls) { remakeView(); return }
    refitImages()
    inStyle = true
    applyLayout()
    inStyle = false
    view?.renderer?.setStyles?.(bookCSS())
    for (const c of view?.renderer?.getContents?.() ?? []) if (c.doc) { calibrate(c.doc); restyle(c.doc) }
}

// After a change, every element is styled and drawn again (WebView2 could
// keep the old colour on the first line of each paragraph).
const restyle = doc => {
    const h = doc?.documentElement
    if (!h) return
    h.classList.add('sable-restyle')
    h.style.setProperty('opacity', '0.999')
    void doc.body?.offsetHeight
    requestAnimationFrame(() => {
        h.classList.remove('sable-restyle')
        h.style.removeProperty('opacity')
    })
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
    // While the app's control menu is open, a click on the page just closes it.
    if (menuOpen) { post('tap'); return }
    if (x < 0.3) view.goLeft()
    else if (x > 0.7) view.goRight()
    else post('tap')
    post('activity')
}

const pageKeys = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', ' ', 'Home', 'End'])

const onKey = e => {
    if ($('#lightbox').classList.contains('show')) {
        e.preventDefault()
        if (e.key === 'Escape') closeLightbox()
        else if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === 'PageDown') stepPicture(1)
        else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'PageUp') stepPicture(-1)
        // Every other shortcut still works (the app's controls, settings and so on).
        else post('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey })
        return
    }
    const tag = e.target?.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA') return
    // A box in the app (like search) is being typed in, but the keyboard is
    // still with the book: every key goes to the app.
    if (typing) {
        e.preventDefault()
        post('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey, typing: true })
        return
    }
    // The app's control menu is driven by the keyboard: keys go to the app only.
    if (menuOpen) {
        if (pageKeys.has(e.key) || e.key === 'Enter') e.preventDefault()
        post('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey })
        return
    }
    if (style.flow === 'scrolled' && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
        const r = view?.renderer
        if (r?.scrollByPx) r.scrollByPx(e.key === 'ArrowDown' ? 120 : -120)
        else smoothScroll(e.key === 'ArrowDown' ? 120 : -120)
    }
    else if (e.key === 'ArrowLeft') view.goLeft()
    else if (e.key === 'ArrowRight') view.goRight()
    else if (e.key === 'PageUp') view.prev()
    else if (e.key === 'PageDown') view.next()
    else if (e.key === 'Home') goChapterEdge(false)
    else if (e.key === 'End') goChapterEdge(true)
    if (pageKeys.has(e.key)) e.preventDefault()
    post('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey })
}

// The mouse wheel: in page mode, one page per notch (small trackpad moves add up
// first); in scroll mode, a smooth eased scroll of a set distance per notch.
let wheelAcc = 0, wheelLock = 0
let scrollAnim = 0
const onWheel = e => {
    if ($('#lightbox').classList.contains('show') || e.ctrlKey) return
    const dy = e.deltaMode === 1 ? e.deltaY * 40 : e.deltaMode === 2 ? e.deltaY * window.innerHeight : e.deltaY
    const dx = e.deltaMode === 1 ? e.deltaX * 40 : e.deltaX
    const d = Math.abs(dy) >= Math.abs(dx) ? dy : dx
    if (!d) return
    // Scroll mode scrolls like a web page (the browser's own smooth scrolling).
    if (view?.renderer?.continuous) { post('activity'); return }
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

// Scroll mode: the wheel adds to a distance still to go, which eases out
// frame by frame. At the top or bottom of a part of the book, a further push
// goes on to the next or previous part.
let scrollLeft = 0, edgePush = 0, edgeTimer = 0, lastFrame = 0
const smoothScroll = d => {
    const r = view?.renderer
    if (!r?.freeScroll) return
    const edge = r.scrollEdge
    const dir = Math.sign(d)
    if (!scrollAnim && (edge === 2 || edge === dir)) {
        edgePush += d
        clearTimeout(edgeTimer)
        edgeTimer = setTimeout(() => { edgePush = 0 }, 900)
        // About five more turns of the wheel to move on to the next chapter.
        if (Math.abs(edgePush) >= 480) {
            edgePush = 0
            scrollLeft = 0
            dir > 0 ? view.next() : view.prev()
        }
        return
    }
    edgePush = 0
    if (Math.sign(scrollLeft) !== dir) scrollLeft = 0
    const h = window.innerHeight
    scrollLeft = Math.max(-h * 2, Math.min(h * 2, scrollLeft + d * 0.55))
    if (!scrollAnim) { lastFrame = 0; scrollAnim = requestAnimationFrame(scrollTick) }
}
const scrollTick = now => {
    const r = view?.renderer
    const dt = lastFrame ? Math.max(4, Math.min(40, now - lastFrame)) : 16
    lastFrame = now
    if (!r || Math.abs(scrollLeft) < 0.6) { scrollLeft = 0; scrollAnim = 0; return }
    const step = scrollLeft * Math.min(1, dt / 110)
    const moved = r.freeScroll(Math.abs(step) < 1 ? Math.sign(step) : step)
    scrollLeft -= step
    if (moved === 0) { scrollLeft = 0; scrollAnim = 0; return }
    scrollAnim = requestAnimationFrame(scrollTick)
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
let stepping = false
const lbImg = () => $('#lightbox img')
const lbApply = () => {
    const im = lbImg()
    im.style.transform = `translate(${lb.x}px, ${lb.y}px) scale(${lb.scale})`
}
const pictureSrc = el => el?.getAttribute?.('src') || el?.src || el?.getAttribute?.('href') || el?.getAttributeNS?.('http://www.w3.org/1999/xlink', 'href') || ''
const pictureEls = doc => [...(doc?.querySelectorAll?.('img, image') ?? [])]
const showPicture = src => new Promise(resolve => {
    const im = lbImg()
    im.onload = () => {
        const fit = Math.min(window.innerWidth * 0.96 / im.naturalWidth, window.innerHeight * 0.96 / im.naturalHeight)
        lb = { scale: fit, x: -im.naturalWidth * fit / 2, y: -im.naturalHeight * fit / 2, drag: null }
        lbApply()
        resolve(im.naturalWidth >= 200 || im.naturalHeight >= 200)
    }
    im.onerror = () => resolve(false)
    im.src = src
})

// Every picture in the book, in order, as (part of the book, nth picture in it).
// Found by reading each part's text, without turning any pages.
let gallery = null, galleryAt = -1
const buildGallery = async () => {
    const out = []
    const secs = view.book.sections
    for (let i = 0; i < secs.length; i++) {
        const s = secs[i]
        if (!s.createDocument) continue
        let doc
        try { doc = await s.createDocument() } catch { continue }
        pictureEls(doc).forEach((_, n) => out.push({ section: i, n }))
    }
    return out
}
// The address of a picture, from the open page or by loading its part of the book.
const parsedParts = new Map()
const gallerySrc = async ({ section, n }) => {
    const shown = view.renderer.getContents().find(c => c.index === section)?.doc
    if (shown) return pictureSrc(pictureEls(shown)[n])
    let doc = parsedParts.get(section)
    if (!doc) {
        const url = await view.book.sections[section].load()
        const text = await (await fetch(url)).text()
        doc = new DOMParser().parseFromString(text, 'application/xhtml+xml')
        if (doc.querySelector('parsererror')) doc = new DOMParser().parseFromString(text, 'text/html')
        parsedParts.set(section, doc)
    }
    return pictureSrc(pictureEls(doc)[n])
}
const openLightbox = (src, el) => {
    const doc = el?.ownerDocument
    const index = view.renderer.getContents().find(c => c.doc === doc)?.index ?? -1
    const n = pictureEls(doc).indexOf(el)
    galleryAt = -1
    gallery = gallery ?? buildGallery()
    Promise.resolve(gallery).then(g => { gallery = g; galleryAt = g.findIndex(p => p.section === index && p.n === n) })
    showPicture(src)
    $('#lightbox').classList.add('show')
    post('lightbox', { open: true })
}
const closeLightbox = () => {
    $('#lightbox').classList.remove('show')
    post('lightbox', { open: false })
    // Parts loaded only for pictures are let go (the open page keeps its own).
    const open = new Set(view.renderer.getContents().map(c => c.index))
    for (const i of parsedParts.keys()) if (!open.has(i)) view.book.sections[i]?.unload?.()
    parsedParts.clear()
}

// The next or previous picture in the whole book, looping round at the ends.
// The page behind stays where it is. Small pictures (decorations) are skipped.
const stepPicture = async dir => {
    if (stepping) return
    stepping = true
    try {
        const g = gallery = await gallery
        if (!g?.length) return
        let at = galleryAt < 0 ? (dir > 0 ? -1 : 0) : galleryAt
        for (let tries = 0; tries < g.length; tries++) {
            at = (at + dir + g.length) % g.length
            let src
            try { src = await gallerySrc(g[at]) } catch { continue }
            if (!src) continue
            galleryAt = at
            if (await showPicture(src)) return
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
// A click on the picture (not a drag) shows or hides the reader's controls.
lbImg().addEventListener('click', e => { e.stopPropagation(); if (!lb.drag?.moved) post('tap') })

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

// Books that size their text in px or pt (or with words like "medium") would
// ignore the text size setting: those sizes are turned into rem, which
// follows the page's text size.
const keywordRem = { 'xx-small': 0.5625, 'x-small': 0.625, small: 0.8125, medium: 1, large: 1.125, 'x-large': 1.5, 'xx-large': 2, 'xxx-large': 3 }
const toRem = v => {
    if (!v) return null
    const m = /^(-?[\d.]+)(px|pt)$/.exec(v.trim())
    if (m) return `${(parseFloat(m[1]) * (m[2] === 'pt' ? 4 / 3 : 1) / 16).toFixed(4)}rem`
    const k = keywordRem[v.trim()]
    return k ? `${k}rem` : null
}
const fixRules = rules => {
    for (const rule of rules ?? []) {
        if (rule.cssRules) fixRules(rule.cssRules)
        const st = rule.style
        if (!st) continue
        const rem = toRem(st.getPropertyValue('font-size'))
        if (rem) st.setProperty('font-size', rem, st.getPropertyPriority('font-size'))
        const lh = st.getPropertyValue('line-height')
        if (/(px|pt)$/.test(lh.trim())) st.removeProperty('line-height')
        // A fixed size on the whole page would win over the setting.
        if (rule.selectorText && /^(html|body|:root)$/i.test(rule.selectorText.trim())) st.removeProperty('font-size')
    }
}
const normalise = doc => {
    try {
        for (const sheet of doc.styleSheets) {
            // Sable's own styles (its text size is meant to be in px).
            if (sheet.ownerNode?.id === 'sable-style' || sheet.ownerNode?.textContent?.startsWith('/*sable*/')) continue
            try { fixRules(sheet.cssRules) } catch {}
        }
        for (const el of doc.querySelectorAll('[style]')) {
            const rem = toRem(el.style.fontSize)
            if (rem) el.style.fontSize = rem
        }
        for (const el of doc.querySelectorAll('font[size]')) el.removeAttribute('size')
        // Empty paragraphs and spacer boxes (used to push text down the page).
        for (const el of doc.body?.querySelectorAll('p, div, span, section') ?? []) {
            if (el.children.length && [...el.children].some(c => c.tagName !== 'BR')) continue
            if ((el.textContent ?? '').replace(/[\s\u00a0\u200b]/g, '') === '') el.classList.add('sable-empty')
        }
    } catch (e) { post('error', { message: 'normalise: ' + e }) }
}

// Text size means the same in every book: the size most of the text is
// drawn at is measured, and the whole page is scaled so it matches the setting
// (headings and small print keep their proportions). Short parts such as
// title pages use the scale found in the rest of the book.
let bookScale = 1, lastCal = null
const calibrate = doc => {
    try {
        const html = doc?.documentElement, body = doc?.body
        if (!body) return
        html.style.removeProperty('font-size')
        body.style.removeProperty('font-size')
        const win = doc.defaultView
        const counts = new Map()
        let total = 0
        const walker = doc.createTreeWalker(body, NodeFilter.SHOW_TEXT)
        let n
        while ((n = walker.nextNode()) && total < 40000) {
            const len = n.nodeValue.replace(/\s+/g, '').length
            if (len < 2) continue
            const el = n.parentElement
            if (!el || el.closest('h1, h2, h3, h4, h5, h6, sup, sub, rt, .sable-empty')) continue
            const fs = parseFloat(win.getComputedStyle(el).fontSize)
            if (!(fs > 0)) continue
            const k = Math.round(fs * 20) / 20
            counts.set(k, (counts.get(k) ?? 0) + len)
            total += len
        }
        let scale = bookScale
        if (total >= 300) {
            let best = 0, most = 0
            for (const [k, c] of counts) if (c > most) { most = c; best = k }
            if (best > 0) scale = Math.max(0.25, Math.min(4, style.size / best))
            bookScale = scale
        }
        lastCal = { total, scale, size: style.size }
        if (Math.abs(scale - 1) < 0.005) return
        const px = `${(style.size * scale).toFixed(3)}px`
        html.style.setProperty('font-size', px, 'important')
        body.style.setProperty('font-size', px, 'important')
    } catch (e) { post('error', { message: 'calibrate: ' + e }) }
}

const onLoad = ({ detail: { doc } }) => {
    normalise(doc)
    calibrate(doc)
    // Measured again once it's on screen (a hidden frame can report other sizes).
    requestAnimationFrame(() => calibrate(doc))
    doc.addEventListener('click', onDocClick)
    doc.addEventListener('keydown', onKey)
    doc.addEventListener('wheel', onWheel, { passive: false })
    doc.addEventListener('mouseup', onMouseButton)
    doc.addEventListener('mousemove', onMove, { passive: true })
    applyCursor(doc)
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

// ---------- the mouse and the app's controls ----------

// Moving the mouse tells the app (it shows the controls); the app hides the
// pointer again when the mouse stops.
let typing = false
let menuOpen = false, lastMove = 0, cursorHidden = false, lastX = -1, lastY = -1
const onMove = e => {
    // Only real movement (pages being laid out under a still mouse also send mousemove).
    if (Math.abs(e.screenX - lastX) + Math.abs(e.screenY - lastY) < 3) return
    lastX = e.screenX
    lastY = e.screenY
    const now = Date.now()
    if (now - lastMove < 150) return
    lastMove = now
    post('move')
}
const cursorCSS = '*, *::before, *::after { cursor: none !important; }'
const applyCursor = doc => {
    let el = doc.getElementById('sable-nocursor')
    if (cursorHidden && !el) {
        el = doc.createElement('style')
        el.id = 'sable-nocursor'
        el.textContent = cursorCSS
        ;(doc.head ?? doc.documentElement).append(el)
    } else if (!cursorHidden && el) el.remove()
}
const setCursor = hidden => {
    cursorHidden = hidden
    applyCursor(document)
    for (const c of view?.renderer?.getContents?.() ?? []) if (c.doc) applyCursor(c.doc)
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
    setMenu: open => { menuOpen = !!open },
    setTyping: on => { typing = !!on },
    setCursor,
    // For the self-test: the size the main text is drawn at, and where we are.
    probe: () => { const d0 = 0; const d = view?.renderer?.getContents?.()[0]?.doc; const p = d?.querySelector('p:not(.sable-empty)'); return { size: p ? parseFloat(d.defaultView.getComputedStyle(p).fontSize) : 0, index: view?.renderer?.getContents?.()[0]?.index ?? -1, edge: view?.renderer?.scrollEdge, start: view?.renderer?.start, cal: lastCal } },
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
window.addEventListener('mousemove', onMove, { passive: true })
// Clicks on the margins around the text (outside the book's pages) work like clicks on the page.
document.addEventListener('click', e => {
    if (e.target?.closest?.('#lightbox') || isInteractive(e.target)) return
    zone(e.clientX / window.innerWidth)
})
window.addEventListener('wheel', onWheel, { passive: false })
window.addEventListener('mouseup', e => onMouseButton(e))
window.addEventListener('auxclick', e => { if (e.button === 3 || e.button === 4) e.preventDefault() })
let resizeTimer
window.addEventListener('resize', () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { refitImages(); applyLayout() }, 120) })

// ---------- start ----------

// The book's view. Scroll mode uses a different engine (one long page), so
// switching between pages and scrolling makes the view again at the same place.
let bookFile = null, viewScrolls = false
const makeView = async () => {
    viewScrolls = style.flow === 'scrolled'
    view = document.createElement('foliate-view')
    view.sableScroll = viewScrolls
    view.addEventListener('relocate', onRelocate)
    view.addEventListener('load', onLoad)
    document.body.append(view)
    await view.open(bookFile)
    chapterLabels()
}
// The chapter names on the dividers between parts in scroll mode.
const chapterLabels = () => {
    const r = view?.renderer
    if (!r?.continuous) return
    const labels = new Map()
    for (const it of flattenToc(view.book.toc)) {
        try {
            const res = view.resolveNavigation(it.href)
            if (res && !labels.has(res.index) && it.label) labels.set(res.index, it.label)
        } catch { }
    }
    r.labels = labels
    r.refreshLabels()
}
let remaking = false
const remakeView = async () => {
    if (remaking || !view || !bookFile) return
    remaking = true
    try {
        const cfi = view.lastLocation?.cfi
        gallery = null
        view.close()
        view.remove()
        await makeView()
        applyStyle()
        await view.init({ lastLocation: cfi ?? null })
    } finally { remaking = false }
}

const main = async () => {
    const init = await (await fetch(`${base}/init/${token}`)).json()
    style = init.style
    theme = init.theme
    applyTheme()
    const blob = await (await fetch(`${base}/book/${token}`)).blob()
    bookFile = new File([blob], init.fileName)
    await makeView()
    $('#message')?.remove()
    applyStyle()
    const book = view.book
    post('ready', {
        toc: flattenToc(book.toc),
        sections: view.getSectionFractions?.() ?? [],
        title: typeof book.metadata?.title === 'string' ? book.metadata.title : '',
        fixed: !!view.isFixedLayout,
    })
    await view.init({ lastLocation: init.position || null, showTextStart: !init.position && !(init.fraction > 0) })
    if (!init.position && init.fraction > 0) await view.goToFraction(init.fraction)
}

main().catch(e => {
    const m = $('#message')
    if (m) m.textContent = 'This book couldn’t be opened.'
    post('failed', { message: String(e?.stack ?? e) })
})

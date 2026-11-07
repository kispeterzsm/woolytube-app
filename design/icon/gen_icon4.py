import math, os
OUT = '/tmp/claude-1000/-home-wooly-Projects-WoolyTube/fc21cf3b-018d-4f7d-a102-01b8662e27cc/scratchpad/icons/v4'

MAMMOTH = ('<path d="M70,60 C73,73 83,74 87,63" fill="none" stroke="#0D3B66" stroke-width="6" '
           'stroke-linecap="round"/>'
           '<path d="M29,70 C24,62 25,52 31,46 C37,39 45,34 54,32 C58,25 70,22 77,30 C81,35 82,42 80,48 '
           'C82,58 84,68 81,75 C79,80 73,80 72,76 C75,70 75,63 70,59 L69,82 L59,82 L59,73 C52,74 47,74 42,73 '
           'L42,82 L33,82 L33,72 Z" fill="#0D3B66"/>')
# Mammoth art spans roughly x 24..87, y 22..82 -> centre (55.5, 52).
MCX, MCY = 55.5, 52.0

def tri(cx, cy, size):
    # Equilateral-ish play triangle pointing right, optically centred.
    h = size; w = size * 0.9
    x0 = cx - w * 0.42; x1 = cx + w * 0.58
    return f'M{x0:.2f},{cy - h/2:.2f} L{x1:.2f},{cy:.2f} L{x0:.2f},{cy + h/2:.2f} Z'

def svg(key, w, h, rx, mscale, tsize, mode, mdx=0.0, mdy=1.5):
    x, y = 54 - w/2, 54 - h/2
    # Rounded triangle look via stroke-linejoin.
    tri_d = tri(54 + 1, 54 + 1, tsize)
    m = (f'<g transform="translate({54+mdx} {54+mdy}) scale({mscale}) translate({-MCX} {-MCY})" '
         f'opacity="0.88">{MAMMOTH}</g>')
    defs = f'''<defs>
<linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="108" y2="108"><stop offset="0" stop-color="#12305A"/><stop offset="1" stop-color="#06111F"/></linearGradient>
<linearGradient id="ice" gradientUnits="userSpaceOnUse" x1="{x}" y1="{y}" x2="{x+w}" y2="{y+h}"><stop offset="0" stop-color="#E1F5FE"/><stop offset="1" stop-color="#4FC3F7"/></linearGradient>
<radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="54" cy="54" r="48"><stop offset="0" stop-color="#4FC3F7" stop-opacity="0.45"/><stop offset="1" stop-color="#4FC3F7" stop-opacity="0"/></radialGradient>
<radialGradient id="tglow" gradientUnits="userSpaceOnUse" cx="55" cy="55" r="{tsize*0.95}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
<clipPath id="block"><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}"/></clipPath>
<mask id="cut"><rect width="108" height="108" fill="white"/><path d="{tri_d}" fill="black" stroke="black" stroke-width="3" stroke-linejoin="round"/></mask>
</defs>'''
    if mode == 'cutout':
        art = f'<g mask="url(#cut)">{m}</g>'
    else:
        art = m
    triangle = ''
    if mode in ('white', 'glow'):
        if mode == 'glow':
            triangle += f'<circle cx="55" cy="55" r="{tsize*0.95}" fill="url(#tglow)"/>'
        triangle += (f'<path d="{tri_d}" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="3" '
                     f'stroke-linejoin="round"/>')
    shine_h = h * 0.26
    body = f'''<rect width="108" height="108" fill="url(#bg)"/>
<circle cx="54" cy="54" r="48" fill="url(#glow)"/>
<g id="fg">
<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="url(#ice)"/>
<g clip-path="url(#block)">
<rect x="{x}" y="{y}" width="{w}" height="{shine_h:.1f}" fill="#FFFFFF" opacity="0.4"/>
{art}
{triangle}
<path d="M{x+7},{y+h*0.62:.1f} L{x+14},{y+h*0.2:.1f}" stroke="#FFFFFF" stroke-width="3.2" stroke-linecap="round" opacity="0.9"/>
<path d="M{x+7},{y+h*0.86:.1f} L{x+9.5},{y+h*0.74:.1f}" stroke="#FFFFFF" stroke-width="2.6" stroke-linecap="round" opacity="0.8"/>
</g>
<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="none" stroke="#FFFFFF" stroke-width="2" opacity="0.75"/>
</g>'''
    s = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="432" height="432">\n<title>WoolyTube - Ice Archive {key}</title>\n{defs}\n{body}\n</svg>\n'
    # Check the block's rounded corners stay inside the 72-unit visible circle.
    cxr, cyr = w/2 - rx, h/2 - rx
    reach = math.hypot(cxr, cyr) + rx
    assert reach <= 36.2, (key, reach)
    open(f'{OUT}/icon-04{key}.svg', 'w').write(s)
    return s

V = {
  'a': dict(w=64, h=44, rx=12, mscale=0.56, tsize=11, mode='white', desc='Wider block, small white play triangle in the middle of the mammoth.'),
  'b': dict(w=64, h=44, rx=12, mscale=0.56, tsize=12, mode='cutout', desc='Same shape, the triangle is cut out of the mammoth so the ice shows through.'),
  'c': dict(w=66, h=40, rx=12, mscale=0.5, tsize=13, mode='white', desc='Wider and slimmer, closer to video proportions, slightly bigger triangle.'),
  'd': dict(w=64, h=44, rx=12, mscale=0.56, tsize=11, mode='glow', desc='Like A, with a soft glow behind the triangle so it pops at small sizes.'),
}
svgs = {k: svg(k, **{kk: vv for kk, vv in v.items() if kk != 'desc'}) for k, v in V.items()}

def inline(s, prefix):
    for ident in ['bg', 'ice', 'glow', 'tglow', 'block', 'cut', 'fg']:
        s = s.replace(f'id="{ident}"', f'id="{prefix}-{ident}"').replace(f'url(#{ident})', f'url(#{prefix}-{ident})')
    return s.replace('width="432" height="432"', 'width="100%" height="100%"')

cards = []
for k, v in V.items():
    big = []
    for shape, css in [('Circle', 'border-radius:50%'), ('Squircle', 'border-radius:30%'), ('Teardrop', 'border-radius:50% 50% 50% 12%')]:
        big.append(f'<figure><div class="mask" style="{css};width:168px;height:168px"><div class="crop">{inline(svgs[k], k+shape)}</div></div><figcaption>{shape}</figcaption></figure>')
    small = []
    for bgname, bg in [('dark', '#202124'), ('light', '#E8EAED')]:
        for px in (48, 32):
            small.append(f'<div class="wall" style="background:{bg}"><div class="mask" style="border-radius:50%;width:{px}px;height:{px}px"><div class="crop">{inline(svgs[k], f"{k}{bgname}{px}")}</div></div><span>{px}px</span></div>')
    cards.append(f'<section><h2>4{k.upper()}</h2><p>{v["desc"]}</p><div class="row">{"".join(big)}</div><div class="row">{"".join(small)}</div></section>')

strip = ''.join(f'<div class="app"><div class="mask" style="border-radius:50%;width:64px;height:64px"><div class="crop">{inline(svgs[k], "s"+k)}</div></div><span>4{k.upper()}</span></div>' for k in V)
orig = open(OUT + '/../icon-04-ice-archive.svg').read()
strip = f'<div class="app"><div class="mask" style="border-radius:50%;width:64px;height:64px"><div class="crop">{inline(orig, "orig").replace("i4-", "o4-")}</div></div><span>Original</span></div>' + strip

html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WoolyTube icon 4 variations</title>
<style>
:root{{--bg:#151515;--card:#222;--text:#eee;--muted:#aaa}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 system-ui,sans-serif;padding:16px}}
h1{{font-size:22px;margin:4px 0 4px}} .lead{{color:var(--muted);margin:0 0 16px}}
section{{background:var(--card);border-radius:14px;padding:16px;margin:0 0 16px}}
h2{{margin:0 0 4px;font-size:18px}} p{{margin:0 0 12px;color:var(--muted)}}
.row{{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-end;margin-bottom:12px}}
figure{{margin:0;text-align:center}} figcaption,span{{color:var(--muted);font-size:12px;display:block;margin-top:6px;text-align:center}}
.mask{{overflow:hidden;position:relative}}
/* Launchers show the middle 72 of the 108 canvas. */
.crop{{position:absolute;left:-25%;top:-25%;width:150%;height:150%}}
.wall{{padding:12px;border-radius:10px;display:flex;flex-direction:column;align-items:center}}
.home{{background:linear-gradient(160deg,#3a4a6b,#1b2133 60%,#2d1f3a);border-radius:14px;padding:20px;display:flex;flex-wrap:wrap;gap:22px;justify-content:center}}
.app span{{color:#fff}}
</style></head><body>
<h1>Icon 4 variations</h1><p class="lead">Wider "video" block with a play triangle. Previews show what a launcher displays (the middle of the adaptive-icon canvas).</p>
{''.join(cards)}
<section><h2>Side by side</h2><div class="home">{strip}</div></section>
</body></html>'''
open(OUT + '/icon-04-variations.html', 'w').write(html)
print('ok')

#!/usr/bin/env python3
"""Build Clippy-AI themes (sprite sheet + agent.json) for free Linux mascots.

  python3 -I tools/mascots/build.py [tux konqi ...]     # default: all

Art lives in tools/mascots/art/ (see themes/CREDITS.md for licences). Tux is rigged from its
layered SVG (wings, pupils, blink, beak); the other mascots are single images animated with
squash/stretch/tilt/hop puppetry. Output format = clippy.js agent.json (+ "sheetScale").
"""
import json, math, sys, tempfile
from pathlib import Path
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
from svglayers import render_layer, render_full

HERE = Path(__file__).parent
ART = HERE / 'art'
OUT = HERE.parent.parent / 'themes'

LW, LH = 120, 120          # logical frame size (what the app scales by "scale")
SS = 2                      # sprite sheet pixels per logical pixel
RS = 2                      # internal supersampling
CW, CH = LW * SS, LH * SS   # cell size in sheet pixels
W, H = CW * RS, CH * RS     # working canvas
FIT_W, FIT_H = int(W * 0.66), int(H * 0.80)
ANCHOR = (W / 2, H - int(H * 0.07))   # feet/bottom-centre of the character
U = RS * SS                 # pose units (dx, dy ...) are logical px -> canvas px


def xform(img, pivot, rot=0.0, sx=1.0, sy=1.0, dx=0.0, dy=0.0):
    """rot: degrees clockwise on screen. Scale/rotate about pivot, then translate."""
    th = math.radians(rot)
    c, s = math.cos(th), math.sin(th)
    m00, m01, m10, m11 = c * sx, -s * sy, s * sx, c * sy
    det = m00 * m11 - m01 * m10
    i00, i01, i10, i11 = m11 / det, -m01 / det, -m10 / det, m00 / det
    px, py = pivot
    cx = px + i00 * (-px - dx) + i01 * (-py - dy)
    cy = py + i10 * (-px - dx) + i11 * (-py - dy)
    pm = img.convert('RGBa')
    out = pm.transform(img.size, Image.AFFINE, (i00, i01, cx, i10, i11, cy), resample=Image.BICUBIC)
    return out.convert('RGBA')


def fit_to_canvas(img):
    img = img.crop(img.getbbox())
    k = min(FIT_W / img.width, FIT_H / img.height)
    img = img.resize((max(1, round(img.width * k)), max(1, round(img.height * k))), Image.LANCZOS)
    canvas = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    canvas.alpha_composite(img, (round(ANCHOR[0] - img.width / 2), round(ANCHOR[1] - img.height)))
    return canvas


class Flat:
    rigged = False
    def __init__(self, base): self.base = base
    def render(self, p):
        return xform(self.base, ANCHOR, p.get('rot', 0), p.get('sx', 1), p.get('sy', 1), p.get('dx', 0) * U, p.get('dy', 0) * U)


TUX_LAYERS = [
    ('body', ['body']), ('wing_left', ['wing_left']), ('wing_right', ['wing_right']),
    ('foot_left', ['foot_left']), ('foot_right', ['foot_right']), ('wing_tip', ['wing_tip_right']),
    ('eyeball_left', ['eyeball_left']), ('pupil_left', ['pupil_left']), ('eyelid_left', ['eyelid_left']), ('eyebrow_left', ['eyebrow_left']),
    ('eyeball_right', ['eyeball_right']), ('pupil_right', ['pupil_right']), ('eyelid_right', ['eyelid_right']), ('eyebrow_right', ['eyebrow_right']),
    ('beak_back', ['beak_shadow', 'beak_base']), ('mand_lower', ['mandible_lower']), ('mand_upper', ['mandible_upper']), ('beak_corner', ['beak_corner']),
]


class Tux:
    rigged = True
    def __init__(self, svg):
        k = min(FIT_W / 216, FIT_H / 256)
        self.k = k
        pw, ph = round(216 * k), round(256 * k)
        ox, oy = round(ANCHOR[0] - pw / 2), round(ANCHOR[1] - ph)
        self.layers = {}
        with tempfile.TemporaryDirectory() as d:
            for name, ids in TUX_LAYERS:
                f = Path(d) / (name + '.png')
                render_layer(svg, set(ids), f, pw, ph)
                im = Image.open(f).convert('RGBA')
                canvas = Image.new('RGBA', (W, H), (0, 0, 0, 0))
                canvas.alpha_composite(im, (ox, oy))
                self.layers[name] = canvas
        self.sv = lambda x, y: (ox + x * k, oy + y * k)     # svg units -> canvas px
        self.piv = {'wl': self.sv(80, 100), 'wr': self.sv(147, 95),
                    'eye_l': self._center('eyeball_left'), 'eye_r': self._center('eyeball_right')}

    def _center(self, n):
        b = self.layers[n].getbbox(); return ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)

    def render(self, p):
        L, k = self.layers, self.k
        wl, wr = p.get('wl', 0), p.get('wr', 0)
        px, py = p.get('px', 0) * U, p.get('py', 0) * U
        blink = p.get('blink', 0); mouth = p.get('mouth', 0); foot = p.get('foot', 0)
        out = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        add = lambda im: out.alpha_composite(im)
        add(L['body'])
        add(xform(L['wing_left'], self.piv['wl'], rot=wl))
        add(xform(L['wing_right'], self.piv['wr'], rot=-wr))
        add(xform(L['foot_left'], self.sv(60, 235), dy=-foot * U))
        add(L['foot_right'])
        add(xform(L['wing_tip'], self.piv['wr'], rot=-wr))
        for side in ('left', 'right'):
            c = self.piv['eye_' + side[0]]
            sy = 1 - 0.88 * blink
            eye = lambda im, extra=(0, 0): xform(im, c, sy=sy, dx=extra[0], dy=extra[1])
            add(eye(L['eyeball_' + side]))
            add(eye(L['pupil_' + side], (px, py)))
            add(eye(L['eyelid_' + side]))
            add(xform(L['eyebrow_' + side], c, dy=p.get('brow', 0) * U - blink * 2 * U))
        add(L['beak_back'])
        add(xform(L['mand_lower'], self.sv(105, 138), dy=mouth * 7 * k))
        add(L['mand_upper'])
        add(L['beak_corner'])
        return xform(out, ANCHOR, p.get('rot', 0), p.get('sx', 1), p.get('sy', 1), p.get('dx', 0) * U, p.get('dy', 0) * U)


# --------------------------------------------------------------------------- animations
S = lambda u, k=1: math.sin(2 * math.pi * u * k)
hop = lambda u, n=1: abs(math.sin(math.pi * u * n))
bump = lambda u: math.sin(math.pi * u)
back = lambda u: 1 + 2.7 * (u - 1) ** 3 + 1.7 * (u - 1) ** 2      # easeOutBack
ENV = [0.35, 0.7, 1, 1, 1, 0.7, 0.35, 0]                       # in / hold / out envelope for Look*/Gesture*


def build_animations(rig):
    A = {}
    def seq(name, n, ms, fn):
        A[name] = [(ms, fn(i / n)) for i in range(n)]
    def env(name, amp_fn, hold=450, ms=60):
        fr = []
        for i, e in enumerate(ENV):
            fr.append((hold if i == 3 else ms, amp_fn(e)))
        A[name] = fr

    A['RestPose'] = [(100, {})]
    seq('IdleBreathe', 10, 130, lambda u: dict(sy=1 + .02 * S(u), sx=1 - .01 * S(u)))
    seq('IdleSideToSide', 12, 110, lambda u: dict(rot=5 * S(u), dx=3 * S(u)))
    seq('IdleHop', 8, 70, lambda u: dict(dy=-9 * hop(u), sy=1 - .05 * (1 - hop(u)), sx=1 + .03 * (1 - hop(u))))
    if rig:
        seq('IdleBlink', 7, 55, lambda u: dict(blink=bump(u)))
        seq('IdleLookAround', 16, 140, lambda u: dict(px=2.6 * S(u), py=-.6 * hop(u)))
        seq('IdleFootTap', 8, 80, lambda u: dict(foot=3 * hop(u, 2)))
    else:
        seq('IdleWiggle', 10, 70, lambda u: dict(rot=3 * S(u, 2), sx=1 + .02 * S(u, 2)))

    if rig:
        env('LookLeft', lambda e: dict(px=-2.6 * e, dx=-3 * e, rot=-3 * e))
        env('LookRight', lambda e: dict(px=2.6 * e, dx=3 * e, rot=3 * e))
        env('LookUp', lambda e: dict(py=-2.6 * e, dy=-2 * e))
        env('LookDown', lambda e: dict(py=2.6 * e, dy=1 * e))
    else:
        env('LookLeft', lambda e: dict(rot=-7 * e, dx=-6 * e))
        env('LookRight', lambda e: dict(rot=7 * e, dx=6 * e))
        env('LookUp', lambda e: dict(sy=1 + .05 * e, dy=-4 * e))
        env('LookDown', lambda e: dict(sy=1 - .05 * e, dy=2 * e))

    seq('Show', 9, 55, lambda u: dict(sx=max(back(u), .01), sy=max(back(u), .01), dy=(1 - u) * -14))
    A['Hide'] = [(55, dict(sx=max(back(1 - i / 9), .01), sy=max(back(1 - i / 9), .01), dy=(i / 9) * -14)) for i in range(9)] + [(60, dict(sx=.01, sy=.01))]
    if rig:
        seq('Wave', 16, 75, lambda u: dict(wr=70 + 22 * S(u, 4), rot=3 * S(u, 2), mouth=.3 * max(0, S(u, 4))))
        seq('Greeting', 18, 75, lambda u: dict(wr=65 + 25 * S(u, 4), dy=-8 * hop(u, 1), mouth=.4 * max(0, S(u, 3)), brow=-1 * bump(u)))
        seq('GetAttention', 14, 60, lambda u: dict(dy=-12 * hop(u, 2), wl=50 * bump(u), wr=50 * bump(u), rot=4 * S(u, 3)))
        seq('Congratulate', 18, 70, lambda u: dict(dy=-14 * hop(u, 2), wl=70 + 15 * S(u, 4), wr=70 + 15 * S(u, 4), mouth=.5 * hop(u, 4)))
        seq('Alert', 12, 50, lambda u: dict(dx=6 * S(u, 5) * (1 - u), sx=1.04, brow=-2, wl=25 * bump(u), wr=25 * bump(u)))
        seq('Thinking', 16, 120, lambda u: dict(rot=-5 * min(1, u * 4), px=-1.8 + .8 * S(u), py=-2.4, wr=60 * min(1, u * 3) * (1 - .1 * S(u, 2)), brow=-1.5))
        seq('Processing', 12, 70, lambda u: dict(rot=3 * S(u, 3), px=2.2 * math.cos(2 * math.pi * u * 2), py=2.2 * math.sin(2 * math.pi * u * 2), dy=-1.5 * hop(u, 6)))
        seq('Searching', 16, 90, lambda u: dict(dx=7 * S(u), px=3 * S(u), rot=3 * S(u), wl=20 * bump(u)))
        seq('CheckingSomething', 14, 90, lambda u: dict(rot=7 * bump(u), py=2.6, px=-1 * S(u), wr=35 * bump(u)))
        seq('Writing', 12, 60, lambda u: dict(wr=12 + 16 * S(u, 6), py=2.2, rot=2 * S(u, 3), dy=-1 * hop(u, 6)))
        seq('GetTechy', 12, 70, lambda u: dict(wl=25 + 20 * S(u, 4), wr=25 - 20 * S(u, 4), px=2 * S(u, 4), rot=2 * S(u, 4)))
        seq('Explain', 16, 80, lambda u: dict(dy=-3 * hop(u, 4), rot=2 * S(u, 2), mouth=max(0, S(u, 8)) * .9, wr=20 + 22 * S(u, 2), wl=8 + 10 * S(u, 2) if u > .5 else 0))
        env('GestureLeft', lambda e: dict(wl=60 * e, rot=-5 * e, dx=-3 * e, px=-2.5 * e, mouth=.6 * e), 700)
        env('GestureRight', lambda e: dict(wr=60 * e, rot=5 * e, dx=3 * e, px=2.5 * e, mouth=.6 * e), 700)
        env('GestureUp', lambda e: dict(wl=75 * e, wr=75 * e, dy=-4 * e, py=-2.5 * e, mouth=.6 * e), 700)
        env('GestureDown', lambda e: dict(wl=-8 * e, wr=-8 * e, dy=2 * e, py=2.5 * e, sy=1 - .04 * e), 700)
    else:
        seq('Wave', 16, 75, lambda u: dict(rot=8 * S(u, 3), dy=-4 * hop(u, 3)))
        seq('Greeting', 18, 75, lambda u: dict(rot=7 * S(u, 3), dy=-10 * hop(u, 2), sy=1 + .03 * S(u, 4)))
        seq('GetAttention', 14, 60, lambda u: dict(dy=-13 * hop(u, 2), rot=5 * S(u, 3), sy=1 + .05 * hop(u, 2)))
        seq('Congratulate', 18, 70, lambda u: dict(dy=-15 * hop(u, 2), rot=9 * S(u, 4), sx=1 + .04 * S(u, 4)))
        seq('Alert', 12, 50, lambda u: dict(dx=6 * S(u, 5) * (1 - u), sx=1.05, sy=.97))
        seq('Thinking', 16, 120, lambda u: dict(rot=-6 * min(1, u * 4) + 1.5 * S(u, 2), dx=-2 * min(1, u * 4), sy=1 + .015 * S(u, 2)))
        seq('Processing', 12, 70, lambda u: dict(rot=5 * S(u, 3), dy=-2 * hop(u, 6)))
        seq('Searching', 16, 90, lambda u: dict(dx=9 * S(u), rot=5 * S(u)))
        seq('CheckingSomething', 14, 90, lambda u: dict(rot=9 * bump(u), dx=4 * bump(u), sy=1 - .03 * bump(u)))
        seq('Writing', 12, 60, lambda u: dict(dy=-2.5 * hop(u, 6), rot=3 * S(u, 3)))
        seq('GetTechy', 12, 70, lambda u: dict(sx=1 + .05 * S(u, 4), sy=1 - .04 * S(u, 4), rot=3 * S(u, 4)))
        seq('Explain', 16, 80, lambda u: dict(dy=-4 * hop(u, 4), rot=3 * S(u, 2), sy=1 + .03 * S(u, 8), sx=1 - .02 * S(u, 8)))
        env('GestureLeft', lambda e: dict(rot=-9 * e, dx=-5 * e, sy=1 + .02 * e), 600)
        env('GestureRight', lambda e: dict(rot=9 * e, dx=5 * e, sy=1 + .02 * e), 600)
        env('GestureUp', lambda e: dict(sy=1 + .08 * e, sx=1 - .03 * e, dy=-5 * e), 600)
        env('GestureDown', lambda e: dict(sy=1 - .07 * e, sx=1 + .04 * e, dy=1 * e), 600)
    return A


def pack(char, anims):
    cols = 16
    cache, cells = {}, []
    def cell(pose):
        key = tuple(sorted((k, round(v, 2)) for k, v in pose.items() if abs(v) > 1e-3))
        if key not in cache:
            cache[key] = len(cells)
            cells.append(char.render(pose).resize((CW, CH), Image.LANCZOS))
        return cache[key]
    spec = {}
    for name, frames in anims.items():
        spec[name] = {'frames': [{'duration': ms, 'idx': cell(p)} for ms, p in frames]}
    rows = math.ceil(len(cells) / cols)
    sheet = Image.new('RGBA', (cols * CW, rows * CH), (0, 0, 0, 0))
    for i, c in enumerate(cells):
        sheet.alpha_composite(c, ((i % cols) * CW, (i // cols) * CH))
    for a in spec.values():
        for f in a['frames']:
            i = f.pop('idx'); f['images'] = [[(i % cols) * CW, (i // cols) * CH]]
    return sheet, spec


MASCOTS = {
    'tux':           dict(make=lambda: Tux(ART / 'tux.svg'), rig=True, credit='Tux by Larry Ewing (GIMP), SVG by Garrett LeSage / Simon Budig'),
    'konqi':         dict(make=lambda: Flat(fit_to_canvas(Image.open(ART / 'konqi.png').convert('RGBA'))), rig=False, credit='Konqi by Tyson Tan (KDE), CC BY-SA 4.0'),
    'konqi-classic': dict(make=lambda: Flat(fit_to_canvas(svg_png(ART / 'konqi-classic.svg'))), rig=False, credit='Konqi (classic, GPL) from Wikimedia Commons'),
    'wilber':        dict(make=lambda: Flat(fit_to_canvas(svg_png(ART / 'wilber.svg'))), rig=False, credit='Wilber, the GIMP mascot, by Matvizz (CC0)'),
    'larry':         dict(make=lambda: Flat(fit_to_canvas(svg_png(ART / 'larry.svg'))), rig=False, credit='Larry the Cow, Gentoo; Ethan Dunham & Matteo Pescarin, CC BY-SA 2.5'),
}


def svg_png(path):
    import subprocess
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / 'o.png'
        subprocess.run(['inkscape', '--export-area-drawing', '-w', '1200', '--export-background-opacity=0',
                        '--export-type=png', '-o', str(f), str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return Image.open(f).convert('RGBA')


def main():
    names = sys.argv[1:] or list(MASCOTS)
    for n in names:
        m = MASCOTS[n]
        print('building', n, flush=True)
        sheet, spec = pack(m['make'](), build_animations(m['rig']))
        d = OUT / n; d.mkdir(parents=True, exist_ok=True)
        sheet.save(d / 'map.png', optimize=True)
        (d / 'agent.json').write_text(json.dumps({
            'name': n, 'overlayCount': 1, 'sounds': [], 'framesize': [LW, LH], 'sheetScale': SS,
            'credit': m['credit'], 'tts': {'rate': 1.0, 'pitch': 1.0}, 'animations': spec}))
        print('  sheet', sheet.size, 'cells', sum(len(a['frames']) for a in spec.values()), 'frames')


if __name__ == '__main__':
    main()

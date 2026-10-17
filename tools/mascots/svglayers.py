"""Split a layered SVG into aligned PNG layers by hiding everything except chosen element ids.
Untrusted SVGs are only rendered (Inkscape, no scripts); nothing from them is executed."""
import copy, subprocess, tempfile, os
from pathlib import Path
from lxml import etree

NS = '{http://www.w3.org/2000/svg}'
DRAWABLE = {NS + 'g', NS + 'path', NS + 'ellipse', NS + 'circle', NS + 'rect', NS + 'polygon'}


def _inside_defs(e):
    return any(p.tag in (NS + 'defs', NS + 'clipPath', NS + 'mask', NS + 'filter') for p in e.iterancestors())


def render_layer(svg_path, keep_ids, out_png, width, height):
    tree = etree.parse(str(svg_path))
    root = tree.getroot()
    keep = [e for e in root.iter() if e.get('id') in keep_ids]
    keep_set = set(keep)
    related = set()
    for k in keep:
        related.add(k)
        related.update(k.iterancestors())
        related.update(k.iterdescendants())
    for e in root.iter():
        if not isinstance(e.tag, str) or e.tag not in DRAWABLE or _inside_defs(e):
            continue
        if e.get('id') and e not in related:
            e.set('style', (e.get('style') or '') + ';opacity:0')
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d) / 'layer.svg'
        tree.write(str(tmp))
        subprocess.run(['inkscape', '--export-area-page', '-w', str(width), '-h', str(height),
                        '--export-background-opacity=0', '--export-type=png', '-o', str(out_png), str(tmp)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def render_full(svg_path, out_png, width, height):
    subprocess.run(['inkscape', '--export-area-page', '-w', str(width), '-h', str(height),
                    '--export-background-opacity=0', '--export-type=png', '-o', str(out_png), str(svg_path)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

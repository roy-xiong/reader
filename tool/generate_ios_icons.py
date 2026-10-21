"""生成 iOS 浅色与深色图标：共享展开书页轮廓；黑灰渐变深色底，系统负责外层圆角。"""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
SCALE = 2
SIZE = 1024


def polygon_curve(points):
    """将三次贝塞尔路径转换为抗锯齿多边形，不依赖外部绘图库。"""
    path = []
    start = points[0]
    path.append(start)
    for c1, c2, end in points[1:]:
        for i in range(1, 49):
            t = i / 48
            u = 1 - t
            path.append((u**3*start[0]+3*u*u*t*c1[0]+3*u*t*t*c2[0]+t**3*end[0],
                         u**3*start[1]+3*u*u*t*c1[1]+3*u*t*t*c2[1]+t**3*end[1]))
        start = end
    return [(round(x*SCALE), round(y*SCALE)) for x, y in path]


def icon(dark=False):
    image = Image.new('RGBA', (SIZE*SCALE, SIZE*SCALE))
    draw = ImageDraw.Draw(image)
    top, bottom = ((43, 44, 47), (10, 11, 13)) if dark else ((249, 246, 232), (226, 235, 220))
    for y in range(SIZE*SCALE):
        t = y/(SIZE*SCALE-1)
        color = tuple(round(a+(b-a)*t) for a, b in zip(top, bottom))
        draw.line((0, y, SIZE*SCALE, y), fill=(*color, 255))
    left = polygon_curve([(222, 300), ((330, 265), (436, 288), (512, 341)),
        ((512, 454), (512, 647), (512, 743)), ((425, 689), (322, 679), (222, 713)),
        ((222, 596), (222, 416), (222, 300))])
    right = polygon_curve([(512, 341), ((588, 288), (694, 265), (802, 300)),
        ((802, 416), (802, 596), (802, 713)), ((702, 679), (599, 689), (512, 743)),
        ((512, 647), (512, 454), (512, 341))])
    if not dark:
        shadow = Image.new('RGBA', image.size)
        d = ImageDraw.Draw(shadow)
        d.polygon([(x, y+22*SCALE) for x, y in left+right], fill=(18, 62, 47, 38))
        image = Image.alpha_composite(image, shadow.filter(ImageFilter.GaussianBlur(22*SCALE)))
    draw = ImageDraw.Draw(image)
    draw.polygon(left, fill='#b6b8bb' if dark else '#285949')
    draw.polygon(right, fill='#e0e0de' if dark else '#3b715b')
    def line(points, fill, width):
        draw.line([(round(x*SCALE), round(y*SCALE)) for x, y in points], fill=fill,
                  width=width*SCALE, joint='curve')
    line([(512, 354), (512, 729)], '#85898d' if dark else '#1f4b3c', 9)
    # 每页三条短笔画避免缩小时形成密集栅格，金色书签提供稳定的识别点。
    for y in (412, 499, 586):
        line([(290, y), (368, y-1), (437, y+22)], '#6d7074' if dark else '#a7c9a7', 14)
        line([(587, y+22), (656, y-1), (734, y)], '#85888a' if dark else '#bfd8b5', 14)
    draw.polygon([(x*SCALE,y*SCALE) for x,y in [(674,293),(719,290),(719,458),(696,440),(674,462)]],
                 fill='#b39a72' if dark else '#bb8347')
    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


if __name__ == '__main__':
    light, dark = icon(), icon(True)
    light.convert('RGB').save(CATALOG/'Icon-Light.png')
    dark.convert('RGB').save(CATALOG/'Icon-Dark.png')
    # 统一图标源由 Xcode 自动生成旧系统所需的各尺寸，移除未分配的旧图。
    for file in CATALOG.glob('Icon-App-*.png'):
        file.unlink()
    catalog = {'images': [
        {'filename': 'Icon-Light.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
        {'appearances': [{'appearance': 'luminosity', 'value': 'dark'}], 'filename': 'Icon-Dark.png',
         'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
    ], 'info': {'author': 'xcode', 'version': 1}}
    (CATALOG/'Contents.json').write_text(json.dumps(catalog, indent=2)+'\n')
    assert light.getextrema()[3] == (255, 255)
    assert dark.getextrema()[3] == (255, 255)
    print('iOS light/dark icons generated; opaque light and charcoal dark checked.')

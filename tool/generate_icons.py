"""生成统一的阅读器平台图标；所有装饰均限制在圆角蒙版内。"""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFilter

root = Path(__file__).resolve().parent.parent
image = Image.new('RGBA', (1024, 1024))
mask = Image.new('L', image.size)
ImageDraw.Draw(mask).rounded_rectangle((96, 96, 928, 928), radius=180, fill=255)
background = Image.new('RGBA', image.size)
draw = ImageDraw.Draw(background)
for y in range(1024):
    t = y / 1023
    color = tuple(round(a + (b - a) * t) for a, b in zip((69, 112, 98), (36, 74, 65)))
    draw.line((0, y, 1024, y), fill=(*color, 255))
image.paste(background, (0, 0), mask)
shadow = Image.new('RGBA', image.size)
ImageDraw.Draw(shadow).ellipse((265, 676, 765, 780), fill=(8, 34, 27, 95))
shadow = shadow.filter(ImageFilter.GaussianBlur(25))
shadow.putalpha(Image.composite(shadow.getchannel('A'), Image.new('L', image.size), mask))
image = Image.alpha_composite(image, shadow)
draw = ImageDraw.Draw(image)
draw.polygon([(272, 306), (466, 330), (512, 360), (512, 734), (466, 706), (272, 680)], fill='#e8e6ce')
draw.polygon([(512, 360), (558, 330), (752, 306), (752, 680), (558, 706), (512, 734)], fill='#fff9e8')
draw.line([(512, 366), (512, 730)], fill='#bdc8ae', width=8)
for y in (410, 478, 546, 614):
    draw.line([(320, y), (456, y + 18)], fill='#a7b498', width=10)
    draw.line([(568, y + 18), (704, y)], fill='#b5c1a7', width=10)
draw.polygon([(673, 316), (711, 311), (711, 474), (692, 459), (673, 478)], fill='#d3a46b')
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    image.resize((size, size), Image.Resampling.LANCZOS).save(root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
icons = root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
for icon in json.loads((icons / 'Contents.json').read_text())['images']:
    size = int(icon['size'].split('x')[0]) * int(icon['scale'][0])
    image.resize((size, size), Image.Resampling.LANCZOS).save(icons / icon['filename'])
for x in (0, 1023):
    assert all(image.getpixel((x, y))[3] == 0 for y in range(1024))
print('平台图标已更新，边缘透明检查通过。')

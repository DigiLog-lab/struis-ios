#!/usr/bin/env python3
"""makepaper.py out.jpg "line1" "line2" ... : handwritten-ish answer photo (Klee font, slight rotation, paper tone)"""
import sys, random
from PIL import Image, ImageDraw, ImageFont, ImageFilter
KLEE="/System/Library/AssetsV2/com_apple_MobileAsset_Font8/81e879dcb4d596ab140f7cffcd5ccaaf8108519b.asset/AssetData/Klee.ttc"
out=sys.argv[1]; lines=sys.argv[2:]
W,H=2400,max(1600,300+len(lines)*200)
im=Image.new("RGB",(W,H),(246,243,235)); d=ImageDraw.Draw(im); f=ImageFont.truetype(KLEE,110)
for y in range(150,H,200): d.line((80,y+130,W-80,y+130),fill=(190,205,225),width=3)
for i,l in enumerate(lines):
    d.text((140+random.randint(-15,15),150+i*200),l,font=f,fill=(35,35,60))
im=im.rotate(random.uniform(-2,2),expand=False,fillcolor=(120,110,100)).filter(ImageFilter.GaussianBlur(1.0))
im.save(out,quality=88)

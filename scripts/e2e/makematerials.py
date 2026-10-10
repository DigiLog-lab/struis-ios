import fitz, random, io, os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
OUT=sys.argv[1]
GOTH="/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
KLEE="/System/Library/AssetsV2/com_apple_MobileAsset_Font8/81e879dcb4d596ab140f7cffcd5ccaaf8108519b.asset/AssetData/Klee.ttc"
random.seed(7)
topics=[("二次関数のグラフ","y = a(x - p)^2 + q の頂点は (p, q)。軸は x = p。"),
("平方完成","y = x^2 - 6x + 5 = (x - 3)^2 - 4 より頂点 (3, -4)。"),
("最大・最小","定義域 0 ≤ x ≤ 4 における y = x^2 - 6x + 5 の最大値は 5、最小値は -4。"),
("判別式","ax^2 + bx + c = 0 の判別式 D = b^2 - 4ac。D > 0 なら異なる2つの実数解。"),
("二次不等式","x^2 - 5x + 6 < 0 の解は 2 < x < 3。"),
("グラフと x 軸の共有点","y = x^2 + 2x + k が x 軸と接するとき k = 1。")]
def textbook(name,pages):
    doc=fitz.open()
    for i in range(pages):
        p=doc.new_page(width=595,height=842)
        t,b=topics[i%len(topics)]
        p.insert_font(fontname="jp",fontfile=GOTH)
        p.insert_text((50,70),f"第{i+1}節 {t}",fontname="jp",fontsize=18)
        y=110
        for k in range(14):
            line=f"{k+1}. {b}" if k%3==0 else f"例{k}: f(x) = {random.randint(1,5)}x^2 - {random.randint(1,9)}x + {random.randint(-5,9)} について、頂点と軸を求めよ。"
            p.insert_text((50,y),line,fontname="jp",fontsize=11); y+=26
        p.draw_line((50,y+10),(545,y+10))
        # simple parabola figure
        pts=[(300+dx*4, 700-((dx/10)**2)*30) for dx in range(-40,41)]
        for a,c in zip(pts,pts[1:]): p.draw_line(a,c)
        p.insert_text((480,820),f"- {i+1} -",fontname="jp",fontsize=9)
    doc.save(os.path.join(OUT,name)); doc.close()
textbook("textbook_6p.pdf",6)
textbook("textbook_40p.pdf",40)
textbook("textbook_200p.pdf",200)
# scanned: rasterize, rotate, noise
src=fitz.open(os.path.join(OUT,"textbook_6p.pdf")); doc=fitz.open()
for pg in src:
    pix=pg.get_pixmap(dpi=200); im=Image.frombytes("RGB",(pix.width,pix.height),pix.samples).convert("L")
    im=im.rotate(random.uniform(-3,3),expand=True,fillcolor=235).filter(ImageFilter.GaussianBlur(0.8))
    px=im.load()
    for _ in range(40000):
        x,y=random.randrange(im.width),random.randrange(im.height); px[x,y]=random.randint(150,255)
    buf=io.BytesIO(); im.save(buf,"JPEG",quality=60)
    p=doc.new_page(width=im.width*72/200,height=im.height*72/200); p.insert_image(p.rect,stream=buf.getvalue())
doc.save(os.path.join(OUT,"scanned_6p.pdf"))
# huge page (A0) and giant single image
doc=fitz.open(); p=doc.new_page(width=2384,height=3370); p.insert_font(fontname="jp",fontfile=GOTH)
for k in range(60): p.insert_text((80,100+k*52),f"巨大ページ {k}: y = x^2 - {k}x + {k*2} の頂点を求めよ",fontname="jp",fontsize=30)
doc.save(os.path.join(OUT,"a0_page.pdf"))
big=Image.new("RGB",(9000,12000),"white"); d=ImageDraw.Draw(big); f=ImageFont.truetype(GOTH,120)
for k in range(40): d.text((200,200+k*290),f"問{k+1} x^2 - {k}x + 2 = 0 を解け",font=f,fill="black")
buf=io.BytesIO(); big.save(buf,"JPEG",quality=85)
doc=fitz.open(); p=doc.new_page(width=595,height=793); p.insert_image(p.rect,stream=buf.getvalue()); doc.save(os.path.join(OUT,"giant_image_page.pdf"))
# encrypted, corrupt, empty-text, zero-page-ish
src=fitz.open(os.path.join(OUT,"textbook_6p.pdf"))
src.save(os.path.join(OUT,"encrypted.pdf"),encryption=fitz.PDF_ENCRYPT_AES_256,user_pw="1234",owner_pw="owner")
data=open(os.path.join(OUT,"textbook_40p.pdf"),"rb").read(); open(os.path.join(OUT,"corrupt_truncated.pdf"),"wb").write(data[:len(data)//3])
open(os.path.join(OUT,"not_a_pdf.pdf"),"wb").write(b"hello this is not a pdf\n"*100)
doc=fitz.open(); doc.new_page(); doc.save(os.path.join(OUT,"blank_1p.pdf"))
# images
def page_img(w,h,lines,font=GOTH,size=60,name=None,fmt="JPEG"):
    im=Image.new("RGB",(w,h),(248,246,240)); d=ImageDraw.Draw(im); f=ImageFont.truetype(font,size)
    for i,l in enumerate(lines): d.text((60,60+i*int(size*1.6)),l,font=f,fill=(30,30,40))
    im.save(os.path.join(OUT,name),fmt,**({"quality":90} if fmt=="JPEG" else {})); return im
probs=["問1 y = x^2 - 4x + 3 の頂点を求めよ","問2 y = 2x^2 + 8x + 5 の軸を求めよ","問3 x^2 - 5x + 6 = 0 を解け","問4 x^2 + 2x + k = 0 が重解をもつ k"]
page_img(8064,6048,probs*6,size=180,name="photo_48mp.jpg")
page_img(24000,2000,["パノラマ "+ " / ".join(probs)],size=200,name="panorama.jpg")
page_img(60,40,["x"],size=20,name="tiny.png",fmt="PNG")
page_img(1179,2556,["スクリーンショット風"]+probs,size=50,name="screenshot.png",fmt="PNG")
page_img(3024,4032,probs,font=KLEE,size=110,name="handwritten_problems.jpg")
os.system(f"sips -s format heic '{OUT}/handwritten_problems.jpg' --out '{OUT}/handwritten_problems.heic' >/dev/null")
# rotated EXIF-like: physically rotated photo
Image.open(os.path.join(OUT,"handwritten_problems.jpg")).rotate(90,expand=True).save(os.path.join(OUT,"rotated90.jpg"),quality=85)
if "--static" not in sys.argv:
    print("done"); sys.exit(0)

# 添付の静的監査(関連する画面・動作)のテストファイル 20 種。
# 13(ProRAW の DNG)・19・20(会話の手順)は実機・手順で扱う。大きいファイル(400MB の mp4・500MB の PDF)は --large で作る。
S=os.path.join(OUT,"static"); os.makedirs(S,exist_ok=True)
def jp(p): p.insert_font(fontname="jp",fontfile=GOTH)
# 1 30 ページ。各ページに大きく PAGE n、20 ページ目だけ固有の問題
doc=fitz.open()
for i in range(30):
    p=doc.new_page(width=595,height=842); jp(p)
    p.insert_text((150,420),f"PAGE {i+1}",fontname="jp",fontsize=72)
    if i==19: p.insert_text((60,520),"固有の問題: 2x^2 - 7x + 3 = 0 を解け(答え x = 3, 1/2)",fontname="jp",fontsize=16)
doc.save(os.path.join(S,"pdf-30p-a4.pdf"))
# 2 user password=test / 3 owner password だけ(印刷禁止)
doc.save(os.path.join(S,"pdf-encrypted-userpw.pdf"),encryption=fitz.PDF_ENCRYPT_AES_256,user_pw="test",owner_pw="owner-test")
doc.save(os.path.join(S,"pdf-owner-only.pdf"),encryption=fitz.PDF_ENCRYPT_AES_256,owner_pw="owner-only",permissions=fitz.PDF_PERM_ACCESSIBILITY|fitz.PDF_PERM_COPY)
doc.close()
# 4 先頭 1KB だけ
open(os.path.join(S,"pdf-corrupt.pdf"),"wb").write(open(os.path.join(OUT,"textbook_6p.pdf"),"rb").read()[:1024])
# 5 Safari のフルページ風(390×20000pt、本文 14pt)
doc=fitz.open(); p=doc.new_page(width=390,height=20000); jp(p)
for k in range(700):
    p.insert_text((16,40+k*28),f"{k+1}行目: 縦長ページの本文。問{k//20+1} の続き y = {k%9+1}x + {k%7}",fontname="jp",fontsize=14)
p.insert_text((16,40+690*28+14),"最後の行: 合言葉は「ひまわり」",fontname="jp",fontsize=14)
doc.save(os.path.join(S,"pdf-safari-fullpage.pdf")); doc.close()
# 6 A4 を /Rotate 90 / mediaBox が cropBox の 2 倍
src=fitz.open(os.path.join(OUT,"textbook_6p.pdf")); doc=fitz.open(); doc.insert_pdf(src,from_page=0,to_page=0)
doc[0].set_rotation(90); doc.save(os.path.join(S,"pdf-rotated-landscape.pdf")); doc.close()
doc=fitz.open(); doc.insert_pdf(src,from_page=0,to_page=0); pg=doc[0]
pg.set_mediabox(fitz.Rect(0,0,1190,1684)); pg.set_cropbox(fitz.Rect(0,842,595,1684)); doc.save(os.path.join(S,"pdf-cropbox-small.pdf")); doc.close()
# 7 14400×14400pt に細かい文字
doc=fitz.open(); p=doc.new_page(width=14400,height=14400); jp(p)
for k in range(200): p.insert_text((100,100+k*70),f"巨大ページ {k}: 細かい文字 x^2 + {k}x + 1",fontname="jp",fontsize=40)
doc.save(os.path.join(S,"pdf-huge-page.pdf")); doc.close()
# 8 スキャン 300dpi 40 ページ(数十 MB)
src40=fitz.open(os.path.join(OUT,"textbook_40p.pdf")); doc=fitz.open()
for pg in src40:
    pix=pg.get_pixmap(dpi=300); im=Image.frombytes("RGB",(pix.width,pix.height),pix.samples)
    px=im.load()
    for _ in range(60000):
        x,y=random.randrange(im.width),random.randrange(im.height); px[x,y]=(random.randint(150,255),)*3
    buf=io.BytesIO(); im.save(buf,"JPEG",quality=88)
    p=doc.new_page(width=595,height=842); p.insert_image(p.rect,stream=buf.getvalue())
doc.save(os.path.join(S,"pdf-scanned-300dpi-40p.pdf")); doc.close()
# 9 2000 ページ(テキストだけ)
doc=fitz.open()
for i in range(2000):
    p=doc.new_page(width=595,height=842); p.insert_text((60,80),f"Page {i+1}: short text {i*7%101}",fontsize=12)
doc.save(os.path.join(S,"pdf-2000p-small.pdf"),garbage=3,deflate=True); doc.close()
# 11 HEIC 48MP とパノラマ 16000×4000
os.system(f"sips -s format heic '{OUT}/photo_48mp.jpg' --out '{S}/heic-48mp.heic' >/dev/null")
page_img(16000,4000,["パノラマ "+" / ".join(probs[:2])],size=260,name="static/panorama-16000x4000.jpg")
os.system(f"sips -s format heic '{S}/panorama-16000x4000.jpg' --out '{S}/panorama-16000x4000.heic' >/dev/null"); os.remove(f"{S}/panorama-16000x4000.jpg")
# 12 縦長スクショ 1170×20000
im=Image.new("RGB",(1170,20000),(255,255,255)); d=ImageDraw.Draw(im); f=ImageFont.truetype(GOTH,40)
for k in range(300): d.text((40,40+k*66),f"{k+1}: 縦長スクショの行。y = {k%9+1}x - {k%5}",font=f,fill=(20,20,20))
d.text((40,40+299*66+33),"最後の行: 合言葉は「あさがお」",font=f,fill=(200,0,0))
im.save(os.path.join(S,"tall-screenshot-1170x20000.png"))
# 13 ProRAW の代わりに 16bit の大きい TIFF(実機の DNG は P6)
Image.open(os.path.join(OUT,"photo_48mp.jpg")).save(os.path.join(S,"large-48mp.tiff"))
# 14 CMYK・16bit・アルファ・アニメ GIF・WebP
base=Image.open(os.path.join(OUT,"handwritten_problems.jpg")).resize((1512,2016))
base.convert("CMYK").save(os.path.join(S,"cmyk.jpg"),quality=90)
Image.new("I;16",(800,600),30000).save(os.path.join(S,"16bit.png"))
a=base.convert("RGBA"); a.putalpha(200); a.save(os.path.join(S,"alpha.png"))
frames=[Image.new("RGB",(400,300),c) for c in ["red","green","blue"]]
for k,fr in enumerate(frames): ImageDraw.Draw(fr).text((20,20),f"frame {k+1}",fill="white",font=ImageFont.truetype(GOTH,40))
frames[0].save(os.path.join(S,"animated.gif"),save_all=True,append_images=frames[1:],duration=300,loop=0)
base.save(os.path.join(S,"photo.webp"),quality=85)
# 15 壊れた JPEG(ヘッダだけ)・SVG・拡張子なしの JPEG
open(os.path.join(S,"broken.jpg"),"wb").write(open(os.path.join(OUT,"handwritten_problems.jpg"),"rb").read()[:600])
open(os.path.join(S,"vector.svg"),"w").write('<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><text x="10" y="50">x^2</text></svg>')
open(os.path.join(S,"noext"),"wb").write(open(os.path.join(OUT,"handwritten_problems.jpg"),"rb").read())
# 16 docx・zip・mp4(小さいもの。大きいものは --large)
os.system(f"cd '{S}' && mkdir -p _docx/word && echo '<w:document/>' > _docx/word/document.xml && (cd _docx && zip -q -r ../doc.docx .) && rm -rf _docx")
os.system(f"cd '{S}' && zip -q archive.zip pdf-corrupt.pdf vector.svg")
os.system(f"ffmpeg -loglevel error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=10 '{S}/clip.mp4'")
# 17 13 ファイル以上のフォルダ(サブフォルダ入り)
F=os.path.join(S,"folder-13"); os.makedirs(os.path.join(F,"sub"),exist_ok=True)
for k in range(13): page_img(400,300,[f"F{k+1}"],size=60,name=f"static/folder-13/f{k+1:02d}.png",fmt="PNG")
page_img(400,300,["sub"],size=60,name="static/folder-13/sub/s1.png",fmt="PNG")
# 18 同じ名前で中身の違う 教材.pdf を 2 件
for tag in ("a","b"):
    os.makedirs(os.path.join(S,f"same-{tag}"),exist_ok=True)
    doc=fitz.open(); p=doc.new_page(); jp(p); p.insert_text((60,100),f"教材 {tag.upper()}: こちらは {tag.upper()} の版",fontname="jp",fontsize=20); doc.save(os.path.join(S,f"same-{tag}","教材.pdf")); doc.close()
if "--large" in sys.argv:
    # 10 500MB の PDF(圧縮できない画像を埋め込む)/ C14 の 400MB の mp4(中身は ftyp の後ろに乱数)
    doc=fitz.open()
    for i in range(60):
        raw=os.urandom(2900*2900*3); im=Image.frombytes("RGB",(2900,2900),raw); buf=io.BytesIO(); im.save(buf,"JPEG",quality=95)
        p=doc.new_page(); p.insert_image(p.rect,stream=buf.getvalue())
    doc.save(os.path.join(S,"pdf-500MB.pdf")); doc.close()
    with open(os.path.join(S,"clip-400MB.mp4"),"wb") as fh:
        fh.write(open(os.path.join(S,"clip.mp4"),"rb").read()); fh.write(os.urandom(400*1024*1024))
print("done")

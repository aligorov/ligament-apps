# Requires: pip install cairosvg pillow
from pathlib import Path
import io,json,shutil
import cairosvg
from PIL import Image,ImageDraw
root=Path(__file__).resolve().parent.parent
source=root/'assets/icons/logo_mark.svg'
master=Image.open(io.BytesIO(cairosvg.svg2png(url=str(source),output_width=2048,output_height=2048))).convert('RGBA')
def icon(size,opaque=False):
    im=master.resize((size,size),Image.Resampling.LANCZOS)
    if opaque:
        bg=Image.new('RGBA',im.size,'white');bg.alpha_composite(im);return bg.convert('RGB')
    return im
for name in ['app_icon.png','logo_mark.png']:icon(1024).save(root/'assets/icons'/name)
for path in [root/'assets/icons/app_icon.ico',root/'windows/runner/resources/app_icon.ico']:
    icon(256).save(path,sizes=[(s,s) for s in [16,24,32,48,64,128,256]])
for platform in ['macos','ios']:
    folder=root/platform/'Runner/Assets.xcassets/AppIcon.appiconset'
    for entry in json.loads((folder/'Contents.json').read_text())['images']:
        if 'filename' not in entry:continue
        size=round(float(entry['size'].split('x')[0])*float(entry['scale'].rstrip('x')))
        icon(size,platform=='ios').save(folder/entry['filename'])
for density,size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    icon(size,True).save(root/f'android/app/src/main/res/mipmap-{density}/ic_launcher.png')
pixels=list(icon(256,True).convert('RGBA').getdata())
header=['// Generated from assets/icons/logo_mark.svg; 256x256 ARGB.','#pragma once','#include <stdint.h>','static const uint32_t c_AppLogoWidth = 256;','static const uint32_t c_AppLogoHeight = 256;','static const uint32_t c_AppLogoPixels[256 * 256] = {']
for i in range(0,len(pixels),16):header.append('    '+', '.join(f'0x{a:02X}{r:02X}{g:02X}{b:02X}' for r,g,b,a in pixels[i:i+16])+',')
header.append('};')
(root/'windows/credential_provider/app_logo_data.h').write_text('\n'.join(header)+'\n')

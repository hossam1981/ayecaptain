# Offline helper: works out which 0.075-degree blocks of assets/land-njny.json have no chart data
# and are inland land. Prints counts and writes landtiles.json + land.png next to itself; the
# rows in lib/widgets/wind_layer.dart (_inlandRows) are the blocks inside the file bbox.
# Needs numpy + Pillow. Edit the json path below before running.
import json,math,collections,sys
import numpy as np
from PIL import Image, ImageDraw
j=json.load(open('/home/claude/ayecaptain/flutter-web/assets/land-njny.json')); ways=[[(p['lng'],p['lat']) for p in w] for w in j['ways']]
T=0.075; W0,S0,E0,N0=j['bbox']; PADD=1.5
# rasterise polygons for fast point tests (prototype only)
RES=0.0015; X0,Y1=W0-PADD,N0+PADD; RW=int((E0-W0+2*PADD)/RES); RH=int((N0-S0+2*PADD)/RES)
img=Image.new('L',(RW,RH),0); d=ImageDraw.Draw(img)
for w in ways: d.polygon([((x-X0)/RES,(Y1-y)/RES) for x,y in w],fill=255)
R=np.asarray(img)>0
def land(lon,lat):
    i=int((lon-X0)/RES); jj=int((Y1-lat)/RES)
    return 0<=i<RW and 0<=jj<RH and R[jj,i]
ix0,ix1=math.floor((W0-PADD)/T),math.ceil((E0+PADD)/T); iy0,iy1=math.floor((S0-PADD)/T),math.ceil((N0+PADD)/T)
has=set()
for w in ways:
    for x,y in w:
        fx,fy=x/T,y/T
        if abs(fx-round(fx))<1e-4 or abs(fy-round(fy))<1e-4: continue
        has.add((math.floor(fx),math.floor(fy)))
for ix in range(ix0,ix1):
    for iy in range(iy0,iy1):
        if land((ix+.5)*T,(iy+.5)*T): has.add((ix,iy))
state={}  # empty tiles: True land / False water
q=collections.deque()
def edge_votes(ix,iy):
    L=n=0
    for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
        nb=(ix+dx,iy+dy)
        if nb not in has: continue
        for k in range(9):
            f=(k+.5)/9
            if dx: lon=(ix+(1 if dx>0 else 0))*T+dx*0.004; lat=(iy+f)*T
            else: lat=(iy+(1 if dy>0 else 0))*T+dy*0.004; lon=(ix+f)*T
            n+=1; L+=land(lon,lat)
    return L,n
empties=[(ix,iy) for ix in range(ix0,ix1) for iy in range(iy0,iy1) if (ix,iy) not in has]
for t in empties:
    L,n=edge_votes(*t)
    if n: state[t]=L*2>n; q.append(t)
while q:
    ix,iy=q.popleft()
    for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
        nb=(ix+dx,iy+dy)
        if nb in has or nb in state or not(ix0<=nb[0]<ix1 and iy0<=nb[1]<iy1): continue
        state[nb]=state[(ix,iy)]; q.append(nb)
print('tiles',(ix1-ix0)*(iy1-iy0),'has',len(has),'empty land',sum(state.values()),'empty water',len(state)-sum(state.values()))
# render
out=Image.new('RGB',(RW//3,RH//3),(120,200,170)); o=ImageDraw.Draw(out); sc=1/(RES*3)
for (ix,iy),l in state.items():
    if l: o.rectangle([((ix*T-X0)*sc,(Y1-(iy+1)*T)*sc),(((ix+1)*T-X0)*sc,(Y1-iy*T)*sc)],fill=(235,225,200))
for w in ways: o.polygon([((x-X0)*sc,(Y1-y)*sc) for x,y in w],fill=(250,245,235))
o.rectangle([((W0-X0)*sc,(Y1-N0)*sc),((E0-X0)*sc,(Y1-S0)*sc)],outline=(255,0,0))
out.save('land.png'); print(out.size)
json.dump(sorted([list(k) for k,v in state.items() if v]),open('landtiles.json','w'))

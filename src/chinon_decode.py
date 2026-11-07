r"""Chinon ES-3000 .DCT -> PNG/JPG decoder.  py chinon_decode.py file.DCT [more.DCT ...]
Format (reverse-engineered Nov 2026): 384-byte 'Cdcx' header, 128-byte info block, then
fixed-size DCT blocks, LSB-first bit fields. Luma: 8x16 blocks; chroma (Cr plane, then Cb):
4:2:0, 8x8 blocks. Each block = DC (luma unsigned 10/8 bits; chroma signed 10 bits in
Superfine, 9 in Fine/Normal) + signed zigzag AC fields of fixed widths."""
import json,os,sys
import numpy as np
from PIL import Image
PARAMS=json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'chinon_params.json')))
RES={0:'SF',1:'F',2:'N'}
_cos={}
def idct_mat(n):
    if n not in _cos:
        k=np.arange(n); M=np.cos(np.pi*(2*k[None,:]+1)*k[:,None]/(2*n))*np.sqrt(2/n); M[0]/=np.sqrt(2); _cos[n]=M
    return _cos[n]
def field(bits,p,L,signed):
    v=(bits[:,p:p+L].astype(np.int64)*(1<<np.arange(L))).sum(1)
    return v-((v>>(L-1))&1)*(1<<L) if signed else v
def plane(buf,n,nbytes,P,bh,bw,gh,gw):
    bits=np.unpackbits(np.frombuffer(buf,np.uint8)[:n*nbytes].reshape(n,nbytes),axis=1,bitorder='little')
    C=np.zeros((n,bh,bw))
    dc=field(bits,0,P['dcL'],bool(P.get('dcSigned')))
    C[:,0,0]=dc*P['A'][0]+P['A'][1]
    for (p,L,rc),q in zip(P['lay'],P['q']): C[:,rc[0],rc[1]]=field(bits,p,L,True)*q
    Mr,Mc=idct_mat(bh),idct_mat(bw)
    blk=np.einsum('ri,nrc,cj->nij',Mr,C,Mc)
    return blk.reshape(gh,gw,bh,bw).transpose(0,2,1,3).reshape(gh*bh,gw*bw)
def _feats(P,K=2):
    p=np.pad(P,K,mode='edge'); H,W=P.shape
    f=[p[K+dy:K+dy+H,K+dx:K+dx+W] for dy in range(-K,K+1) for dx in range(-K,K+1)]
    return np.stack(f+[np.ones_like(P)],-1)
def postfilter(Y,Cb,Cr,Wt):
    """Learned 5x5 filter that reproduces the original Chinon software's look
    (half-pixel shift, mild sharpening, tone) plus smooth chroma upsampling."""
    H,W=Y.shape
    up=lambda c: np.asarray(Image.fromarray(c.astype(np.float32),'F').resize((W,H),Image.BILINEAR))
    return _feats(Y)@Wt[0], _feats(up(Cb))@Wt[1], _feats(up(Cr))@Wt[2]
def decode(data):
    if data[:4]==b'Cdcx': res=data[12]; data=data[384:]
    else: res=data[4]
    P=PARAMS[RES[res]]; W,H=P['W'],P['H']; yb,cb=P['ybytes'],P['cbytes']
    ny=(W//16)*(H//8); nc=(W//16)*(H//16); o=128
    Y=plane(data[o:],ny,yb,P['y'],8,16,H//8,W//16); o+=ny*yb
    Cr=plane(data[o:],nc,cb,P['cr'],8,8,H//16,W//16); o+=nc*cb
    Cb=plane(data[o:],nc,cb,P['cb'],8,8,H//16,W//16)
    if 'post' in PARAMS:
        Y,Cb,Cr=postfilter(Y,Cb,Cr,np.array(PARAMS['post']))
    else:
        up=lambda c: np.repeat(np.repeat(c,2,0),2,1)
        Cr,Cb=up(Cr),up(Cb)
    R=Y+Cr/0.713; B=Y+Cb/0.564; G=(Y-0.299*R-0.114*B)/0.587
    return Image.fromarray(np.clip(np.stack([R,G,B],-1),0,255).round().astype(np.uint8)),RES[res]
if __name__=='__main__':
    files=sys.argv[1:] or [f for f in os.listdir('.') if f.upper().endswith('.DCT')]
    for f in files:
        img,res=decode(open(f,'rb').read()); out=os.path.splitext(f)[0]+'.png'
        img.save(out); print(f'{f} ({res}, {img.width}x{img.height}) -> {out}')

def decode_thumbnail(data, res):
    """Camera thumbnail (command 56) -> small PIL image.
    The thumbnail is simply the first byte(s) of every compressed block of the full picture:
    luma blocks (1 byte in N/F, 2 in SF), then all chroma blocks (2 bytes each), FF padding.
    Decoding only the DC terms gives a 1/8-scale image (80x60 for SF/F, 40x30 for N)."""
    if isinstance(res, int): res = RES[res]
    P = PARAMS[res]; W, H = P['W'], P['H']
    gh, gw = H // 8, W // 16; ch, cw = H // 16, W // 16
    ny, nc = gh * gw, 2 * ch * cw
    yb = 2 if len(data) >= ny * 2 + nc * 2 else 1
    raw = np.frombuffer(data, np.uint8)
    if len(raw) < ny * yb + nc * 2:
        raise ValueError('thumbnail too short')
    yraw = raw[:ny * yb].reshape(ny, yb)
    craw = raw[ny * yb:ny * yb + nc * 2].reshape(nc, 2)
    def dcs(rawb, Pp, n, g):
        bits = np.unpackbits(np.ascontiguousarray(rawb), axis=1, bitorder='little')
        dc = field(bits, 0, Pp['dcL'], bool(Pp.get('dcSigned')))
        return dc * Pp['A'][0] + Pp['A'][1]
    Y = dcs(yraw, P['y'], ny, (gh, gw)).reshape(gh, gw) / np.sqrt(128)
    Cr = dcs(craw[:nc // 2], P['cr'], nc // 2, (ch, cw)).reshape(ch, cw) / 8
    Cb = dcs(craw[nc // 2:], P['cb'], nc // 2, (ch, cw)).reshape(ch, cw) / 8
    Y = np.repeat(Y, 2, 1)                              # 8x16 blocks -> square cells
    Cr = np.repeat(np.repeat(Cr, 2, 0), 2, 1); Cb = np.repeat(np.repeat(Cb, 2, 0), 2, 1)
    R = Y + Cr / 0.713; B = Y + Cb / 0.564; G = (Y - 0.299 * R - 0.114 * B) / 0.587
    return Image.fromarray(np.clip(np.stack([R, G, B], -1), 0, 255).round().astype(np.uint8))

"""Reference (Python) for the fused WHOOP 4 step estimator, run continuously on R10 frames.

Per strap/person agnostic gates (no owner-specific constants):
  window = 10 R10 frames (~9.6 s), hop 5 frames; a window is WALKING when
    orientation wobble (SD of the firmware gravity vector, R10 floats @46) <= 0.18 g  and
    accel-magnitude autocorrelation peak over lags 0.35-1.2 s >= 0.25.
  Frames covered by any walking window form bouts (split on counter/time gaps).
  Per bout: gyro-cadence steps (app detector port) if >= 0.7 x firmware counter delta
  (R10 u16 @1293), else the firmware delta (arm not swinging: bag/phone).
Validated n=1 (2026-09-23): whole 30-min stream 722.5 vs 750 labelled (-3.7 %), 0 false steps on
typing / hand-to-mouth / hand-talk (both wrists). See docs/WHOOP4_PROTOCOL_FINDINGS.md.
"""
import sys,json,struct,math
sys.argv=['x']; exec(open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)),'strap_metrics.py')).read().replace('if __name__ == "__main__":\n    main()',''))
FSR=100/0.96143
def load_frames(path):
    out=[]
    for line in open(path):
        if '"k":"r10"' not in line: continue
        r=json.loads(line); p=bytes.fromhex(r['hex'])
        ax=[struct.unpack_from('<100h',p,o) for o in (85,285,485)]
        gy=[struct.unpack_from('<100h',p,o) for o in (688,888,1088)]
        g=struct.unpack_from('<3f',p,46)
        out.append({'g':g,'w':r['w'],'seq':int.from_bytes(p[3:5],'little'),'ts':int.from_bytes(p[7:11],'little'),
          'fw':int.from_bytes(p[1293:1295],'little'),
          'amag':[math.sqrt(sum((ax[i][k]/4096)**2 for i in range(3))) for k in range(100)],
          'rot':[math.sqrt(sum(gy[i][k]**2 for i in range(3)))*GYR_SCALE for k in range(100)]})
    out.sort(key=lambda f:f['w']); return out
def periodicity(x):
    mu=sum(x)/len(x); x=[v-mu for v in x]; var=sum(v*v for v in x)/len(x)
    if var<1e-6: return 0.0
    best=0.0
    for lag in range(int(0.35*FSR),int(1.2*FSR)):
        n=len(x)-lag; c=sum(x[i]*x[i+lag] for i in range(n))/n/var
        best=max(best,c)
    return best
def grav_sd(w):
    n=len(w); m=[sum(f['g'][i] for f in w)/n for i in range(3)]
    return math.sqrt(sum(sum((f['g'][i]-m[i])**2 for f in w)/n for i in range(3)))
def fused(frames, win=10, hop=5, thr=0.25, ratio=0.7, gsd=0.18):
    total=0.0; bouts=[]
    for sp in spans(frames):
        walk=[False]*len(sp)
        for i in range(0, max(1,len(sp)-win+1), hop):
            w=sp[i:i+win]
            if len(w)>=5 and grav_sd(w)<=gsd and periodicity([v for f in w for v in f['amag']])>=thr:
                for j in range(i,i+len(w)): walk[j]=True
        run=[]
        for f,ok in list(zip(sp,walk))+[(None,False)]:
            if ok: run.append(f); continue
            if run:
                g=span_steps([v for x in run for v in x['rot']])[0]
                fw=(run[-1]['fw']-run[0]['fw'])&0xffff
                st=g if g>=ratio*fw else fw
                total+=st; bouts.append((run[0]['w'],run[-1]['w'],round(g,1),fw,round(st,1)))
            run=[]
    return total,bouts
if __name__=='__main__':
    import datetime
    frames=load_frames('/tmp/atria-ble/long-raw.jsonl')
    labs=[json.loads(l) for f in ('walk-labels','cond-labels','control-labels') for l in open(f'/tmp/atria-ble/{f}.jsonl')]
    lo=min(l['start'] for l in labs)-60; hi=max(l['stop'] for l in labs)+60
    sel=[f for f in frames if lo<=f['w']<=hi]
    tot,bouts=fused(sel)
    truth=sum(l['truth_steps'] for l in labs)
    fmt=lambda w: datetime.datetime.fromtimestamp(w).strftime('%H:%M:%S')
    for b in bouts: print(fmt(b[0]),'-',fmt(b[1]),'gyro',b[2],'fw',b[3],'->',b[4])
    print('WHOLE STREAM %s-%s: fused %.1f vs labelled truth %d (err %+.1f%%)'%(fmt(lo),fmt(hi),tot,truth,100*(tot-truth)/truth))
    # per-label attribution
    for l in labs:
        s=sum(b[4]*max(0,min(b[1],l['stop']+6)-max(b[0],l['start']-3))/max(1e-9,b[1]-b[0]) for b in bouts)
        print(f"  {l['label']:26s} truth {l['truth_steps']:3d} fused~{s:6.1f}")

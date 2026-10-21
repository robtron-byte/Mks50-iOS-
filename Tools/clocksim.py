# Simulation of the MIDI clock sync logic (Python port of SynthEngine.handleClock
# and the MIDIManager source lock). Run: python3 Tools/clocksim.py
# Note: the "OLD" rows label transport-only as "no clk"; the old app showed "int".
# Port of SynthEngine clock state machine (handleClock, clockFreeRunning, render counter)
# plus MIDIManager source lock. Simulates USB hardware scenarios at 120 BPM.
SR=48000; BUF=256
class Engine:
    def __init__(s, timeout_frames):
        s.T=timeout_frames; s.since=10**12; s.running=False; s.stopped=False; s.local=False
        s.ticks=0; s.beat=0.0; s.rate=1.0
    def silent(s): return s.since>s.T
    def free(s): return s.local or (not s.stopped and s.silent())
    def label(s):
        if s.free(): return 'no clk' if (s.running and not s.local) else 'int'
        return 'ext>' if s.running else 'ext#'
    def clock(s,st):
        if st==0xF8:
            wasFree=s.free() and not s.local; s.since=0
            if wasFree: s.ticks=0; s.beat=0; s.rate=1; s.running=True
            if not s.running: return
            tgt=s.ticks/24; s.ticks+=1; err=tgt-s.beat
            if err>1: s.beat=tgt; s.rate=1
            else: s.rate=min(max(1+err*2,.5),1.5)
        elif st==0xFA: s.ticks=0;s.beat=0;s.running=True;s.rate=1;s.stopped=False;s.local=False;s.since=0
        elif st==0xFC: s.running=False;s.stopped=True;s.local=False
    def render(s,n,bpm=120):
        following=not s.free()
        r=(s.rate if s.running else 0) if following else 1
        s.beat+=bpm/60/SR*n*r; s.since+=n
class Lock:
    def __init__(s): s.src=None; s.t=-1
    def accept(s,src,t):
        if src!=s.src and not (s.t<0 or t-s.t>0.5): return False
        s.src=src; s.t=t; return True
def run(name,events,lock,timeout):
    e=Engine(timeout); L=Lock(); q=[]; labels=[]; t=0.0; ev=sorted(events); i=0
    while t<6:
        while i<len(ev) and ev[i][0]<=t:
            _,src,st=ev[i]; i+=1
            if not lock or L.accept(src,ev[i-1][0]): q.append(st)
        for st in q: e.clock(st)
        q=[]; e.render(BUF); t+=BUF/SR
        if abs((t*4)-round(t*4))<BUF/SR*2: labels.append(e.label())
    beats=e.beat
    print(f"{name:42s} labels t=0.25..: {' '.join(labels[::2][:12])}  beat@6s={beats:.2f} (ideal ~{(6-1)*2:.1f})")
tick=60/120/24
def clockstream(src,start=1.0,jitter=None,dup=False,send_clock=True):
    ev=[(start,src,0xFA)]
    if send_clock:
        k=0;t=start
        while t<6:
            tt=t if not jitter else t+jitter(k)
            ev.append((tt,src,0xF8))
            if dup: ev.append((tt+0.0002,'port2',0xF8))
            k+=1;t+=tick
    if dup: ev.append((start+0.0002,'port2',0xFA))
    return ev
# USB batching: ticks delivered in bursts every 30 ms (several at once)
burst=lambda k: (-(k*tick)%0.03)
for lock,timeout,tag in [(False,SR//2,'OLD (0.5s, no lock)'),(True,SR,'NEW (1s, source lock)')]:
    print('==',tag)
    run('normal USB clock',clockstream('usb'),lock,timeout)
    run('clock on 2 ports (duplicated)',clockstream('usb',dup=True),lock,timeout)
    run('bursty USB delivery',clockstream('usb',jitter=burst),lock,timeout)
    run('Start only, clock send off',clockstream('usb',send_clock=False),lock,timeout)

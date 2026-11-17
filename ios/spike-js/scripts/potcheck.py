import json,urllib.request,re,sys
r=json.load(open(sys.argv[1])); lines=open(sys.argv[2]).read().splitlines()
urls={row['video']:row['url'] for row in r['rows']}
for ln in lines:
    cls='ACCEPTED' if ' ACCEPTED ' in ln else 'rejected'
    pots=dict(kv.split('=',1) for kv in ln.split() if kv.count('=')>=1 and not kv.startswith(('flags=','init=','mint=','it=')))
    res=[]
    for vid,pot in pots.items():
        u=urls[vid]+'&pot='+pot
        clen=int(re.search(r'[?&]clen=(\d+)',u).group(1))
        st=[]
        for rng in [f'{clen//2}-{clen//2+4095}', f'{clen-256}-{clen-1}']:
            req=urllib.request.Request(u,headers={'Range':'bytes='+rng,'User-Agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0'})
            try:
                with urllib.request.urlopen(req,timeout=20) as resp: st.append(resp.status)
            except urllib.error.HTTPError as e: st.append(e.code)
        res.append(f'{vid}:{st}')
    print(ln.split()[1], cls, ' '.join(res))

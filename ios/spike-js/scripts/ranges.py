import json,urllib.request,re,sys
r=json.load(open(sys.argv[1]))
pot=sys.argv[2] if len(sys.argv)>2 else None
for row in r['rows']:
    u=row['url']
    if pot: u+='&pot='+pot
    clen=int(re.search(r'[?&]clen=(\d+)',u).group(1))
    out=[]
    for rng in ['0-4095', f'{clen//2}-{clen//2+4095}', f'{clen-256}-{clen-1}']:
        req=urllib.request.Request(u,headers={'Range':'bytes='+rng,'User-Agent':'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0'})
        try:
            with urllib.request.urlopen(req,timeout=20) as resp: out.append(resp.status)
        except urllib.error.HTTPError as e: out.append(e.code)
    print(row['video'], clen, out)

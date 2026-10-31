import json,sys,os
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
import digsp
src,dst=sys.argv[1:3]
n=ch=0;ex=[];bad=0
with open(src,encoding="utf-8") as f, open(dst,"w",encoding="utf-8",newline="") as o:
    for line in f:
        n+=1
        body=line.rstrip("\n")
        d=json.loads(body)
        k="reference" if "reference" in d else "text"
        new=digsp.fix(d[k])
        if new==d[k]:
            o.write(line); continue
        out=None
        for ea in (False,True):
            a=json.dumps(d[k],ensure_ascii=ea); b=json.dumps(new,ensure_ascii=ea)
            key='"%s": %s'%(k,a)
            if body.count(key)==1:
                out=body.replace(key,'"%s": %s'%(k,b)); break
        if out is None:
            bad+=1; o.write(line); continue
        d3=dict(d); d3[k]=new
        assert json.loads(out)==d3
        o.write(out+("\n" if line.endswith("\n") else "")); ch+=1
        ex.append((d["id"],d[k],new))
print(dst,"rows",n,"changed",ch,"unwritable",bad)
json.dump(ex,open(dst+".changes.json","w"),ensure_ascii=False)

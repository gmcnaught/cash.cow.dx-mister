import sys,struct,os,collections
f=open(sys.argv[1],'rb');out=sys.argv[2]
assert f.read(4)==b'GDPC'
fmt,maj,mi,pa,flags,base=struct.unpack('<5IQ',f.read(28));f.read(64)
n=struct.unpack('<I',f.read(4))[0]
print('fmt',fmt,'ver',maj,mi,pa,'flags',hex(flags),'base',hex(base),'n',n)
ext=collections.Counter();files=[]
for i in range(n):
    l=struct.unpack('<I',f.read(4))[0];p=f.read(l).rstrip(b'\0').decode()
    off,sz=struct.unpack('<QQ',f.read(16));f.read(16);fl=struct.unpack('<I',f.read(4))[0]
    files.append((p,base+off,sz,fl));ext[p.rsplit('.',1)[-1]]+=1
print(ext.most_common())
for p,o,s,fl in files:
    if fl: print('FLAG',p,fl)
    if p.endswith(('project.binary','.gdc','.gd','.gdextension','.remap','.cfg','.tscn','.tres','.gdshader','.import','.json','.txt','.csv')) or 'uid_cache' in p or 'extension_list' in p:
        d=os.path.join(out,p.replace('res://',''));os.makedirs(os.path.dirname(d),exist_ok=True)
        cur=f.tell();f.seek(o);open(d,'wb').write(f.read(s));f.seek(cur)
with open(os.path.join(out,'_index.txt'),'w') as w:
    for p,o,s,fl in files: w.write(f'{s:10d} {p}\n')

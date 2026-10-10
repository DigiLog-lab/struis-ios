/* SPDX-License-Identifier: Apache-2.0 */
// Worker-only synchronous guest requests. The host owns all native authority.
export function synchronousBroker(buffer) {
  const state=new Int32Array(buffer,0,4),bytes=new Uint8Array(buffer,16);
  let sequence=0;
  return request=>{
    if(Atomics.load(state,2))throw Error('virtual filesystem cancelled');
    const body=new TextEncoder().encode(JSON.stringify({...request,sequence:++sequence}));
    if(body.length>bytes.length)throw Error('virtual filesystem request budget');
    bytes.set(body);Atomics.store(state,1,body.length);Atomics.store(state,0,1);
    postMessage({filesystemRequest:true,sequence});
    const deadline=Date.now()+10000;
    while(Atomics.load(state,0)!==2){
      if(Atomics.load(state,2)||Date.now()>deadline)throw Error('virtual filesystem cancelled or timed out');
      Atomics.wait(state,0,1,100);
    }
    const length=Atomics.load(state,1);
    if(length<0||length>bytes.length)throw Error('virtual filesystem response budget');
    const result=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes.slice(0,length)));
    Atomics.store(state,0,0);
    if(result.sequence!==sequence)throw Error('virtual filesystem response sequence');
    return result;
  };
}
export function installWorkspace(py,request,onDenied=()=>{}) {
 const FS=py.FS,E=py.ERRNO_CODES,root='/workspace',maximum=16384,identities=new Map(),references=new Map(),denials=[];
 let nextIdentity=1;
 const identity=node=>{if(node.virtualIdentity!==undefined)return node.virtualIdentity;const p=path(node);if(!identities.has(p))identities.set(p,nextIdentity++);return node.virtualIdentity=identities.get(p);};
 const fail=n=>{throw new FS.ErrnoError(E[n]);};
 const call=(operation,args={})=>{const r=request({operation,...args});if(r.errno){
  // CPython translates errno into strerror and may discard the JS message.
  // Retain only bounded sanitized broker reasons, never paths/handles/payloads.
  if(r.errno==='EACCES'&&typeof r.message==='string'&&r.message.length<=512&&denials.length<16){const denied={operation,errno:r.errno,message:r.message};denials.push(denied);onDenied({...denied});}
  const error=new FS.ErrnoError(E[r.errno]??E.EIO);error.message=r.message;throw error;
 }return r;};
 // Root liveness check preserves existing mount-denial observations. The
 // following read-only policy comes only from this origin's captured broker.
 const rootMetadata=call('metadata',{path:''}).metadata;
 const policy=call('descriptorPolicy').policy;
 const extent=value=>{if(typeof value!=='string'||!/^[1-9][0-9]*$/.test(value))throw Error('descriptor policy envelope');const n=Number(value);if(!Number.isSafeInteger(n)||String(n)!==value)throw Error('descriptor policy is not a safe integer');return n;};
 if(!policy||Object.keys(policy).sort().join(',')!=='configured,readExtent,writeExtent'||typeof policy.configured!=='boolean')throw Error('descriptor policy envelope');
 const readExtent=extent(policy.readExtent),writeExtent=extent(policy.writeExtent);
 if(!policy.configured&&(readExtent!==16*1024*1024||writeExtent!==16*1024*1024))throw Error('legacy descriptor policy mismatch');
 const positionValue=value=>{if(!Number.isSafeInteger(value)||value<0)fail('EINVAL');return String(value);};
 const path=node=>{let p=[];while(node.parent!==node){p.push(node.name);node=node.parent;}return p.reverse().join('/');};
 const mode=m=>(m.directory?0o040700:0o100600);
 const attrs=(node,m)=>({dev:0x485954,ino:identity(node),mode:mode(m),nlink:1,uid:0,gid:0,rdev:0,size:(Number.isSafeInteger(m.bytes)&&m.bytes>=0?m.bytes:fail('EOVERFLOW')),atime:new Date(m.modified??0),mtime:new Date(m.modified??0),ctime:new Date(m.created??0),blksize:4096,blocks:Math.ceil(m.bytes/512)});
 const metadata=node=>node.handles?.size?call('stat',{handle:[...node.handles][0]}).metadata:call('metadata',{path:path(node)}).metadata;
 const create=(parent,name,m)=>{const node=FS.createNode(parent,name,mode(m),0);node.node_ops=nodeOps;node.stream_ops=streamOps;node.handles=new Set();return node;};
 const nodeOps={
  getattr:node=>attrs(node,metadata(node)),
  setattr:(node,a)=>{if(a.size!==undefined){const h=call('open',{path:path(node),flags:2}).handle;try{call('truncate',{handle:h,length:positionValue(a.size)});}finally{call('close',{handle:h});}}else if(a.mode!==undefined&&node.initialCreationMode){delete node.initialCreationMode;}else fail('ENOTSUP');},
  lookup:(parent,name)=>create(parent,name,call('metadata',{path:[path(parent),name].filter(Boolean).join('/')}).metadata),
  mknod:(parent,name,m)=>{const p=[path(parent),name].filter(Boolean).join('/');identities.delete(p);if(FS.isDir(m))call('mkdir',{path:p});else if(FS.isFile(m)){const h=call('open',{path:p,flags:2|4|8}).handle;call('close',{handle:h});}else fail('ENOTSUP');const node=create(parent,name,call('metadata',{path:p}).metadata);if(FS.isFile(m))node.initialCreationMode=true;return node;},
  readdir:node=>['.','..',...call('list',{path:path(node)}).names],
  unlink:(parent,name)=>call('remove',{path:[path(parent),name].filter(Boolean).join('/'),recursive:false}),
  rmdir:(parent,name)=>call('remove',{path:[path(parent),name].filter(Boolean).join('/'),recursive:false}),
  rename:(node,newDir,newName)=>{
   const source=path(node),destination=[path(newDir),newName].filter(Boolean).join('/');
   let replaced;try{replaced=FS.lookupNode(newDir,newName);}catch(e){if(e.errno!==E.ENOENT)throw e;}
   // Retained open nodes keep distinct virtual identities after replacement.
   identity(node);if(replaced)identity(replaced);
   call('rename',{source,destination});
   // The broker succeeded before any guest cache mutation. Emscripten's
   // FS.rename updates parent and rehashes the source after this callback.
   if(replaced&&replaced!==node)FS.hashRemoveNode(replaced);
   const moved=[...identities].filter(([p])=>p===source||p.startsWith(source+'/'));
   for(const p of [...identities.keys()])if(p===source||p.startsWith(source+'/')||p===destination||p.startsWith(destination+'/'))identities.delete(p);
   for(const [p,id]of moved)identities.set(destination+p.slice(source.length),id);
   node.name=newName;
  },symlink:()=>fail('ENOTSUP'),readlink:()=>fail('ENOTSUP')
 };
 const streamOps={
  open:s=>{const f=s.flags;if(f&~(3|64|128|512|1024|32768|524288|65536))fail('ENOTSUP');if(FS.isDir(s.node.mode))return;if(f&65536)fail('ENOTDIR');let flags=(f&3)===0?1:(f&3)===1?2:3;if(f&64)flags|=4;if(f&128)flags|=8;if(f&512)flags|=16;if(f&1024)flags|=32;s.handle=call('open',{path:path(s.node),flags}).handle;s.node.handles.add(s.handle);references.set(s.handle,1);},
  dup:s=>{if(s.handle)references.set(s.handle,(references.get(s.handle)??0)+1);},
  close:s=>{if(s.handle){const remaining=(references.get(s.handle)??1)-1;if(remaining){references.set(s.handle,remaining);return;}try{call('close',{handle:s.handle});}finally{references.delete(s.handle);s.node.handles.delete(s.handle);}}},
  read:(s,b,offset,length,position)=>{const r=call('read',{handle:s.handle,offset:positionValue(position),length:Math.min(length,maximum)});const raw=atob(r.data);for(let i=0;i<raw.length;i++)b[offset+i]=raw.charCodeAt(i);return raw.length;},
  write:(s,b,offset,length,position)=>{let data='';const n=Math.min(length,maximum);for(let i=0;i<n;i++)data+=String.fromCharCode(b[offset+i]&255);return call('write',{handle:s.handle,offset:positionValue(position),data:btoa(data)}).written;},
  llseek:(s,offset,whence)=>{let p=offset;if(whence===1)p+=s.position;else if(whence===2)p+=metadata(s.node).bytes;else if(whence!==0)fail('EINVAL');const mode=s.flags&3,limit=mode===0?readExtent:mode===1?writeExtent:Math.max(readExtent,writeExtent);if(!Number.isSafeInteger(p)||p<0||p>limit)fail('EINVAL');return p;},
  mmap:()=>fail('ENOTSUP'),msync:()=>fail('ENOTSUP')
 };
 const backend={mount:()=>create(null,'/',rootMetadata)};
 // Pinned Pyodide includes inert Node-only backend definitions. Never expose/mount them.
 const allowedMounts=new Set([FS.filesystems.MEMFS,backend]);
 for(const name of Object.keys(FS.filesystems).filter(name=>name!=='MEMFS')){delete FS.filesystems[name];if(py._module)delete py._module[name];}
 const originalMount=FS.mount;
 FS.mount=(type,...args)=>{if(!allowedMounts.has(type))fail('ENOTSUP');return originalMount(type,...args);};
 FS.mkdirTree(root);FS.mount(backend,{},root);
 // Preserve open descriptor truncation instead of reopening its pathname.
 const nativeFtruncate=FS.ftruncate;
 FS.ftruncate=(fd,length)=>{const s=FS.getStreamChecked(fd);if(s.handle)return call('truncate',{handle:s.handle,length:positionValue(length)});return nativeFtruncate(fd,length);};
 // Ordinary Python filesystem syscall routes cannot write virtual packages/system.
 // This does not make arbitrary guest JavaScript memory/FS object mutation immutable.
 // Inodes are synthetic node identities, not native device/inode values.
 const writable=p=>{const n=typeof p==='string'?py.PATH.normalize(p.startsWith('/')?p:FS.cwd()+'/'+p):FS.getPath(p);return n===root||n.startsWith(root+'/')||n==='/dev/capture_stderr'||n==='/dev/stderr';};
 const originalOpen=FS.open;
 FS.open=(p,flags,...args)=>{if(typeof flags==='string')flags=FS.modeStringToFlags(flags);if((flags&3)!==0||flags&(64|512|1024)){if(!writable(p))fail('EROFS');}return originalOpen(p,flags,...args);};
 for(const name of ['mkdir','mknod','unlink','rmdir','truncate','chmod','utime','symlink','rename']){const old=FS[name];if(!old)continue;FS[name]=(...args)=>{if(!writable(args[0]))fail('EROFS');if(name==='symlink')fail('ENOTSUP');if(name==='rename'){const normalized=p=>typeof p==='string'?py.PATH.normalize(p.startsWith('/')?p:FS.cwd()+'/'+p):FS.getPath(p);const source=normalized(args[0]),destination=normalized(args[1]);if(!source.startsWith(root+'/')||!destination.startsWith(root+'/'))fail('EROFS');if(source===destination)return call('rename',{source:source.slice(root.length+1),destination:destination.slice(root.length+1)});}return old(...args);};}
 FS.chdir(root);
 return {deniedOperations:()=>denials.map(item=>({...item}))};
}

/* SPDX-License-Identifier: Apache-2.0 */
// Binary data stays binary. Only the dedicated Worker waits; UI transport is async.
export const STDIO_FRAME = 16384;
function installCallbacks(FS,ERRNO_CODES,setStdin,setStdout,setStderr,buffer) {
 const state=new Int32Array(buffer,0,8),bytes=new Uint8Array(buffer,32);
 let sequence=0,eof=false;
 const errors=['EIO','ECANCELED','EPIPE','EINVAL','EIO','EACCES'];
 const request=(operation,input,length)=>{
  if(Atomics.load(state,3))throw new FS.ErrnoError(ERRNO_CODES.EINTR);
  if(input)bytes.set(input.subarray(0,length));
  Atomics.store(state,1,operation);Atomics.store(state,2,length);Atomics.store(state,7,++sequence);Atomics.store(state,0,1);
  postMessage({stdioRequest:true,sequence});
  const deadline=Date.now()+10000;
  while(Atomics.load(state,0)!==2){
   if(Atomics.load(state,3)||Date.now()>deadline)throw new FS.ErrnoError(ERRNO_CODES.EINTR);
   Atomics.wait(state,0,1,100);
  }
  const error=Atomics.load(state,4),count=Atomics.load(state,5),ended=Atomics.load(state,6);
  if(Atomics.load(state,7)!==sequence||count<0||count>length)throw new FS.ErrnoError(ERRNO_CODES.EIO);
  Atomics.store(state,0,0);
  if(error)throw new FS.ErrnoError(ERRNO_CODES[errors[error]??'EIO']??ERRNO_CODES.EIO);
  return {count,eof:ended===1};
 };
 setStdin({isatty:false,read:target=>{
  if(eof||!target.length)return 0;
  const answer=request(1,null,Math.min(target.length,STDIO_FRAME));
  target.set(bytes.subarray(0,answer.count));eof=answer.eof;return answer.count;
 }});
 const write=(stream,target)=>{const input=new Uint8Array(target.buffer,target.byteOffset,target.byteLength);if(!input.length)return 0;return request(stream,input,Math.min(input.length,STDIO_FRAME)).count;};
 setStdout({isatty:false,write:target=>write(2,target)});
 setStderr({isatty:false,write:target=>write(3,target)});
}
export function createBinaryStdioPump(buffer,provider,signal) {
 const state=new Int32Array(buffer,0,8),bytes=new Uint8Array(buffer,32);
 let pending=null,serving=false,stopped=false;
 const empty=()=>new Uint8Array(0);
 const delay=()=>new Promise(resolve=>setTimeout(resolve,5));
 const exchange=async(stdoutData,stderrData,stdinCapacity)=>{
  if(stopped||signal.aborted)throw Error('stdio transport cancelled');
  const reply=await provider.exchange({stdoutData,stderrData,stdinCapacity},signal);
  if(!reply||!(reply.stdinData instanceof Uint8Array)||reply.stdinData.length>stdinCapacity||typeof reply.stdinEOF!=='boolean')throw Error('stdio reply envelope');
  for(const [name,limit]of [['stdoutAccepted',stdoutData.length],['stderrAccepted',stderrData.length]])if(!Number.isInteger(reply[name])||reply[name]<0||reply[name]>limit)throw Error('stdio acceptance envelope');
  return reply;
 };
 // One acknowledged exchange at a time, including idle heartbeats during cold load.
 const heartbeat=setInterval(()=>{
  if(stopped||serving||pending||heartbeatFailure)return;
  pending=exchange(empty(),empty(),0).finally(()=>{pending=null;});
  pending.catch(error=>{heartbeatFailure=error;}); // Never replay an unknown acknowledgement.
 },500);
 let heartbeatFailure;
 const stop=()=>{stopped=true;clearInterval(heartbeat);Atomics.store(state,3,1);Atomics.notify(state,0);};
 return {
  async serve(sequence){
   if(serving||stopped||Atomics.load(state,0)!==1||Atomics.load(state,7)!==sequence)throw Error('stdio request state');
   serving=true;
   try{
    if(pending)await pending;
    if(heartbeatFailure)throw heartbeatFailure;
    const operation=Atomics.load(state,1),length=Atomics.load(state,2);
    if(![1,2,3].includes(operation)||length<1||length>STDIO_FRAME)throw Error('stdio request envelope');
    const output=operation===1?empty():bytes.slice(0,length);
    let reply,count;
    do {
     reply=await exchange(operation===2?output:empty(),operation===3?output:empty(),operation===1?length:0);
     if(reply.errno){const map={ECANCELED:1,EPIPE:2,EINVAL:3,EIO:4,EACCES:5};Atomics.store(state,4,map[reply.errno]??4);count=0;break;}
     count=operation===1?reply.stdinData.length:operation===2?reply.stdoutAccepted:reply.stderrAccepted;
     if(!count&&!(operation===1&&reply.stdinEOF))await delay();
    }while(!count&&!(operation===1&&reply.stdinEOF));
    if(stopped||signal.aborted)return;
    if(operation===1)bytes.set(reply.stdinData);
    if(!reply.errno)Atomics.store(state,4,0);
    Atomics.store(state,5,count);Atomics.store(state,6,reply.stdinEOF?1:0);Atomics.store(state,0,2);Atomics.notify(state,0);
   }finally{serving=false;}
  },
  async finish(exitCode){clearInterval(heartbeat);if(pending)await pending;if(heartbeatFailure)throw heartbeatFailure;return provider.finish(exitCode,signal);},
  stop
 };
}

// Real Emscripten FS stream operations, not a Pyodide compatibility object.
export function installEmscriptenBinaryStdio(Module,buffer){
 const FS=Module.FS;
 function bind(fd,write){const stream=FS.getStream(fd);if(!stream)throw Error('output descriptor unavailable');stream.stream_ops={...stream.stream_ops,write(_stream,target,offset,length){return write(target.subarray(offset,offset+length));}};}
 function input({read}){const stream=FS.getStream(0);if(!stream)throw Error('stdin descriptor unavailable');stream.stream_ops={...stream.stream_ops,read(_stream,target,offset,length){return read(target.subarray(offset,offset+length));}};}
 installCallbacks(FS,Module.ERRNO_CODES,input,({write})=>bind(1,write),({write})=>bind(2,write),buffer);
}

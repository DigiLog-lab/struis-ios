/* SPDX-License-Identifier: Apache-2.0 */
// Main/UI thread performs asynchronous transport only; no Atomics.wait here.
export async function runVirtualPython(code) { return runJob({code}); }
export async function runVirtualPythonCommand(argv,provider,options={}) {
 if(!Array.isArray(argv)||argv.length<1||argv.length>256)throw Error('argv budget');
 const encoded=argv.map(a=>typeof a==='string'?new TextEncoder().encode(a):a instanceof Uint8Array?a.slice():null);
 if(encoded.some(a=>!a||a.includes(0)||a.length>16384)||encoded.reduce((n,a)=>n+a.length+1,0)>65536)throw Error('argv budget');
 if(![1,2].includes(provider?.functionID)||(provider.functionID===2&&options.gitHistoryTestOnly!==true))throw Error('unsupported virtual provider entry; Git history requires the trusted test-only asset opt-in');
 if(!provider||typeof provider.exchange!=='function'||typeof provider.finish!=='function'||typeof provider.cancel!=='function')throw Error('trusted provider unavailable');
 const {createBinaryStdioPump}=await import('./stdio.js');
 return runJob({argv:encoded,functionID:provider.functionID,gitHistoryTestOnly:provider.functionID===2},provider,options,createBinaryStdioPump);
}
async function runJob(job,provider,options={},createPump) {
 const buffer=new SharedArrayBuffer(16+65536),state=new Int32Array(buffer,0,4),bytes=new Uint8Array(buffer,16);
 const worker=new Worker('./worker.js',{type:'module'});
 const transport=new AbortController();
 const stdio=provider?new SharedArrayBuffer(32+16384):null;
 const pump=provider?createPump(stdio,provider,transport.signal):null;
 let busy=false,ended=false;
 return new Promise((resolve,reject)=>{
  const stop=()=>{ended=true;Atomics.store(state,2,1);Atomics.notify(state,0);worker.terminate();pump?.stop();transport.abort();clearTimeout(timer);options.signal?.removeEventListener('abort',cancel);};
  const cancelNative=async()=>{
   if(!provider)return;
   let deadline;
   try{const reply=await Promise.race([Promise.resolve().then(()=>provider.cancel()),new Promise((_,fail)=>{deadline=setTimeout(()=>fail(Error('native cancellation confirmation timeout')),8000);})]);if(reply?.completed!==true)throw Error('native cancellation unconfirmed');}
   finally{clearTimeout(deadline);}
  };
  const cancel=()=>{if(ended)return;stop();cancelNative().then(()=>resolve({success:false,cancelled:true,exitCode:130,deniedOperations:[]})).catch(reject);};
  const timer=setTimeout(()=>{if(provider)cancel();else{stop();reject(Error('virtual Python deadline'));}},25000);
  options.signal?.addEventListener('abort',cancel,{once:true});
  if(options.signal?.aborted){cancel();return;}
  const fail=error=>{if(ended)return;stop();cancelNative().then(()=>reject(error),reject);};
  worker.onerror=e=>fail(Error(e.message));
  worker.onmessage=async e=>{
   if(e.data.stdioRequest){
    try{await pump.serve(e.data.sequence);}catch(error){fail(error);}
   }else if(e.data.filesystemRequest){
    if(busy||ended||Atomics.load(state,0)!==1){fail(Error('filesystem envelope state'));return;}
    busy=true;
    try{
     const length=Atomics.load(state,1);if(length<1||length>bytes.length)throw Error('request budget');
     const body=bytes.slice(0,length);
     const response=await fetch('./broker',{method:'POST',headers:{'Content-Type':'application/json'},body,signal:transport.signal});
     if(!response.ok)throw Error('broker transport rejected');
     const expected=Number(response.headers.get('Content-Length'));if(!Number.isInteger(expected)||expected<1||expected>bytes.length)throw Error('response budget');
     const reader=response.body.getReader(),result=new Uint8Array(expected);let received=0;
     while(true){const {value,done}=await reader.read();if(done)break;if(received+value.length>expected){await reader.cancel();throw Error('response budget');}result.set(value,received);received+=value.length;}
     if(received!==expected)throw Error('response length');
     if(ended)return;bytes.set(result);Atomics.store(state,1,result.length);Atomics.store(state,0,2);Atomics.notify(state,0);
    }catch(error){fail(error);}finally{busy=false;}
   }else if(e.data.done){
    try{if(provider){const reply=await pump.finish(e.data.result.exitCode??1);if(reply?.completed!==true||!Number.isInteger(reply.exitCode)||reply.exitCode<-(2**31)||reply.exitCode>=2**31)throw Error('native completion unconfirmed');if(reply.exitCode!==e.data.result.exitCode)e.data.result={...e.data.result,success:false,exitCode:reply.exitCode,error:e.data.result.error||'native stdio execution failed'};}if(ended)return;stop();resolve(e.data.result);}
    catch(error){fail(error);}
   }
  };
  worker.postMessage({buffer,stdio,...job});
 });
}

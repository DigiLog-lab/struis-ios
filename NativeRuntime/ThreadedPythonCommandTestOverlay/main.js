/* SPDX-License-Identifier: Apache-2.0; isolated real-runtime foundation. */
export async function runVirtualPython(code,options={}) {return runJob({code},undefined,options);}
export async function runVirtualPythonCommand(argv,provider,options={}) {
 if(!Array.isArray(argv)||argv.length<1||argv.length>256)throw Error('argv budget');
 const encoded=argv.map(a=>typeof a==='string'?new TextEncoder().encode(a):a instanceof Uint8Array?a.slice():null);
 if(encoded.some(a=>!a||a.includes(0)||a.length>16384)||encoded.reduce((n,a)=>n+a.length+1,0)>65536)throw Error('argv budget');
 if(provider?.functionID!==1)throw Error('unsupported virtual provider entry');
 if(typeof provider.exchange!=='function'||typeof provider.finish!=='function'||typeof provider.cancel!=='function')throw Error('trusted provider unavailable');
 return runJob({argv:encoded},provider,options);
}
async function runJob(job,provider,options={}) {
 const code=job.code;
 if(!provider&&(typeof code!=='string'||new TextEncoder().encode(code).length>65536))throw Error('Python code budget');
 const buffer=new SharedArrayBuffer(16+65536),state=new Int32Array(buffer,0,4),bytes=new Uint8Array(buffer,16);
 const stdio=provider?new SharedArrayBuffer(32+16384):null;
 const {createBinaryStdioPump}=await import('./stdio.js');
 const worker=new Worker('./worker.js',{type:'module'}),transport=new AbortController();
 const pump=provider?createBinaryStdioPump(stdio,provider,transport.signal):null;
 let ending=false,cancelPending=false,busy=false,retiredResolve,retiredReject;
 const retired=new Promise((resolve,reject)=>{retiredResolve=resolve;retiredReject=reject;});
 const wake=()=>{Atomics.store(state,2,1);Atomics.notify(state,0);pump?.stop();transport.abort();};
 let watchdog;
 return new Promise((resolve,reject)=>{
  const settle=async(result)=>{
   if(ending)return;ending=true;clearTimeout(watchdog);options.signal?.removeEventListener('abort',cancel);
   try{
    wake();worker.postMessage({control:'retire',sequence:1});
    let timer;const ack=await Promise.race([retired,new Promise((_,fail)=>{timer=setTimeout(()=>fail(Error('owned pthread retirement unconfirmed')),8000);})]).finally(()=>clearTimeout(timer));
    if(ack.running!==0||ack.unused!==0||ack.pthreads!==0)throw Error('owned pthread retirement incomplete');
    // Worker.terminate is asynchronous. Keep the owner alive for event delivery;
    // direct CDP target destruction is verified externally, not inferred here.
    await new Promise(done=>setTimeout(done,50));worker.terminate();
    resolve({...result,pthreadRetirement:ack});
   }catch(error){worker.terminate();reject(error);}
  };
  const cancel=async()=>{
   if(ending||cancelPending)return;cancelPending=true;
   try{
    const nativeCancel=provider?()=>provider.cancel():options.nativeCancel;
    if(typeof nativeCancel!=='function')throw Error('trusted native cancellation unavailable');
    let timer;const reply=await Promise.race([nativeCancel(),new Promise((_,fail)=>{timer=setTimeout(()=>fail(Error('native cancellation confirmation timeout')),8000);})]).finally(()=>clearTimeout(timer));
    if(reply?.completed!==true)throw Error('native cancellation unconfirmed');
    await settle({success:false,cancelled:true,exitCode:130,deniedOperations:[],nativeCancellationConfirmed:true});
   }catch(error){await settle({success:false,error:String(error),cancelled:true,exitCode:130,nativeCancellationConfirmed:false});}
  };
  const fail=async(error)=>{if(!ending&&!cancelPending){if(provider){cancelPending=true;let cancelDeadline;try{const reply=await Promise.race([provider.cancel(),new Promise((_,reject)=>{cancelDeadline=setTimeout(()=>reject(Error('native cancellation confirmation timeout')),8000);})]);if(reply?.completed!==true)throw Error('native cancellation unconfirmed');}catch(cancelError){error=cancelError;}finally{clearTimeout(cancelDeadline);}}await settle({success:false,error:String(error)});}};
  worker.onerror=e=>{retiredReject(Error(e.message));fail(Error(e.message));};
  worker.onmessage=async({data})=>{
   if(data.retirement){retiredResolve(data.retirement);return;}
   if(data.stdioRequest){try{await pump.serve(data.sequence);}catch(error){fail(error);}return;}
   if(data.done){if(!ending&&!cancelPending){try{let result=data.result;if(provider){const reply=await pump.finish(result.exitCode??1);if(reply?.completed!==true||!Number.isInteger(reply.exitCode)||reply.exitCode<-(2**31)||reply.exitCode>=2**31)throw Error('native completion unconfirmed');if(reply.exitCode!==result.exitCode)result={...result,success:false,exitCode:reply.exitCode,error:result.error||'native stdio execution failed'};}await settle(result);}catch(error){fail(error);}}return;}
   if(data.filesystemRequest){
    if(ending)return;
    if(busy||Atomics.load(state,0)!==1){fail(Error('filesystem envelope state'));return;}
    busy=true;
    try{
     const length=Atomics.load(state,1);if(length<1||length>bytes.length)throw Error('request budget');
     const response=await fetch('./broker',{method:'POST',headers:{'Content-Type':'application/json'},body:bytes.slice(0,length),signal:transport.signal});
     if(!response.ok)throw Error('broker transport rejected');
     const expected=Number(response.headers.get('Content-Length'));if(!Number.isInteger(expected)||expected<1||expected>bytes.length)throw Error('response budget');
     const reader=response.body.getReader(),result=new Uint8Array(expected);let received=0;
     while(true){const{value,done}=await reader.read();if(done)break;if(received+value.length>expected){await reader.cancel();throw Error('response budget');}result.set(value,received);received+=value.length;}
     if(received!==expected)throw Error('response length');
     if(ending)return;bytes.set(result);Atomics.store(state,1,result.length);Atomics.store(state,0,2);Atomics.notify(state,0);
    }catch(error){if(!ending)fail(error);}finally{busy=false;}
   }
  };
  watchdog=setTimeout(cancel,60000);options.signal?.addEventListener('abort',cancel,{once:true});
  if(options.signal?.aborted){cancel();return;}
  worker.postMessage({buffer,stdio,...job});
 });
}

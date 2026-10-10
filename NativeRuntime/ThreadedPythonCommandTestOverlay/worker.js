/* SPDX-License-Identifier: Apache-2.0; scratch actual-runtime foundation only. */
import {installEmscriptenBinaryStdio} from './stdio.js';
import createPython from './python.mjs';
import {synchronousBroker,installWorkspace} from './filesystem.js';
const boundedText=(value,limit=4096)=>{const bytes=new TextEncoder().encode(String(value));return new TextDecoder().decode(bytes.subarray(0,limit));};
const digest=async bytes=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
async function fixedAsset(item){const bytes=new Uint8Array(await(await fetch(item.url)).arrayBuffer());if(await digest(bytes)!==item.sha256)throw Error('trusted artifact hash mismatch');return bytes;}
async function unpack(FS,data,prefix){const d=new DataView(data.buffer,data.byteOffset,data.byteLength);let end=data.length-22;while(end>=0&&d.getUint32(end,true)!==0x06054b50)end--;if(end<0)throw Error('zip directory');let pos=d.getUint32(end+16,true);const count=d.getUint16(end+10,true);for(let i=0;i<count;i++){if(d.getUint32(pos,true)!==0x02014b50)throw Error('zip entry');const method=d.getUint16(pos+10,true),packed=d.getUint32(pos+20,true),plain=d.getUint32(pos+24,true),nl=d.getUint16(pos+28,true),xl=d.getUint16(pos+30,true),cl=d.getUint16(pos+32,true),off=d.getUint32(pos+42,true);const name=new TextDecoder('utf-8',{fatal:true}).decode(data.slice(pos+46,pos+46+nl));pos+=46+nl+xl+cl;if(name.startsWith('/')||name.split('/').includes('..'))throw Error('zip path');if(name.endsWith('/'))continue;const start=off+30+d.getUint16(off+26,true)+d.getUint16(off+28,true);let value=data.slice(start,start+packed);if(method===8)value=new Uint8Array(await new Response(new Blob([value]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());else if(method!==0)throw Error('zip compression');if(value.length!==plain)throw Error('zip size');const path=prefix+'/'+name;FS.mkdirTree(path.slice(0,path.lastIndexOf('/')));FS.writeFile(path,value);}}
let ownerModule=null,runtimeOwned=false,factorySettled=false,retireRequested=false,retirementSent=false,jobStarted=false;
function retireOwned(){
 if(retirementSent)return;
 if(jobStarted&&!runtimeOwned&&!factorySettled)return;
 const p=ownerModule?.PThread;
 if(p){p.terminateAllThreads();}
 const retirement={running:p?.runningWorkers.length??0,unused:p?.unusedWorkers.length??0,pthreads:p?Object.keys(p.pthreads).length:0,controller:p?'actual Emscripten PThread.terminateAllThreads':'no runtime started',terminationRequested:true};
 if(retirement.running||retirement.unused||retirement.pthreads)throw Error('owned pthread retirement incomplete');
 retirementSent=true;postMessage({retirement});
}
onmessage=async({data})=>{
 if(data.control==='retire'){if(data.sequence!==1)throw Error('retirement sequence');retireRequested=true;retireOwned();return;}
 if(jobStarted||retireRequested)throw Error('one trusted job per owner');jobStarted=true;
 const output=[],errors=[],denials=[];let capturedBytes=0,outputTruncated=false;
 function capture(target,value){const text=boundedText(value),size=new TextEncoder().encode(text).length;if(target.length>=256||capturedBytes+size>65536){outputTruncated=true;return;}if(text!==String(value))outputTruncated=true;capturedBytes+=size;target.push(text);}
 let finalSent=false,setupStage='manifest';
 function finish(result){if(finalSent||retireRequested)return;finalSent=true;retireOwned();postMessage({done:true,result:{...result,output,errors,outputTruncated,deniedOperations:denials,browser:{isolated:crossOriginIsolated,nativeBridge:false,runtimeProfile:'sync-proxy-no-jspi',optionalJSPIIOEnabled:false,hostFeatures:{Suspending:typeof WebAssembly.Suspending,promising:typeof WebAssembly.promising,SAB:typeof SharedArrayBuffer}}}});}
 globalThis.addEventListener('error',event=>{factorySettled=true;finish({success:false,error:boundedText('actual Worker error '+event.message+' '+event.error?.stack)});});
 try{
  if(!crossOriginIsolated||typeof SharedArrayBuffer!=='function'||typeof process!=='undefined'||typeof require!=='undefined')throw Error('isolated browser required');
  if(data.argv&&(!Array.isArray(data.argv)||data.argv.length<1||data.argv.length>256||data.argv.some(x=>!(x instanceof Uint8Array)||x.includes(0)||x.length>16384)||data.argv.reduce((n,x)=>n+x.length+1,0)>65536))throw Error('argv budget');
  const manifest=await(await fetch('./inventory.json')).json();if(retireRequested){retireOwned();return;}
  const nativeMap=Object.fromEntries(manifest.native.map(x=>[x.guest,x])),broker=synchronousBroker(data.buffer);
  const config={noInitialRun:true,arguments:['-c',data.code],dynamicLibraries:manifest.native.map(x=>x.guest),locateFile:(path,prefix)=>nativeMap[path]?.url??prefix+path,
   print:s=>capture(output,s),printErr:s=>capture(errors,s),stdin:()=>null,
   preRun(Module){runtimeOwned=true;ownerModule=Module;if(retireRequested){retireOwned();return;}Module.ENV.PYTHONHOME='/';Module.ENV.PYTHONPATH='/lib/site-packages';Module.FS.mkdirTree('/lib/python3.14/lib-dynload');Module.addRunDependency('trusted-inputs');(async()=>{
    if(data.argv){const source=await fixedAsset({url:'./hyotan_runner.py',sha256:'2e9eccfaddad11c0d5b2e0cf9ca07b852ce81e70ca99e3193ad1944d087b0702'});if(source.length>65536)throw Error('runner budget');Module.FS.mkdirTree('/lib/site-packages');Module.FS.writeFile('/lib/site-packages/hyotan_runner.py',source);}
    for(const item of manifest.files){if(retireRequested)return;setupStage='trusted input '+item.url;const bytes=await fixedAsset(item);if(item.unpack)await unpack(Module.FS,bytes,'/lib/site-packages');else{Module.FS.mkdirTree(item.guest.slice(0,item.guest.lastIndexOf('/')));Module.FS.writeFile(item.guest,bytes);}}
    for(const item of manifest.native){if(retireRequested)return;setupStage='native file '+item.url;const bytes=await fixedAsset(item);Module.FS.mkdirTree(item.guest.slice(0,item.guest.lastIndexOf('/')));Module.FS.writeFile(item.guest,bytes);}
    Module.removeRunDependency('trusted-inputs');
   })().catch(error=>{factorySettled=true;finish({success:false,error:boundedText(setupStage+' errno='+error?.errno+' '+(error?.message||String(error)))});});},
   onRuntimeInitialized(){runtimeOwned=true;ownerModule=this;if(retireRequested){retireOwned();return;}setupStage='workspace mount after actual FS.init';try{if(data.argv)installEmscriptenBinaryStdio(this,data.stdio);installWorkspace({FS:this.FS,PATH:this.PATH,ERRNO_CODES:this.ERRNO_CODES,_module:this},broker,x=>{if(denials.length<16)denials.push(x);});if(Object.keys(this.FS.filesystems).some(n=>n!=='MEMFS'))throw Error('foreign filesystem backend');}catch(error){finish({success:false,error:boundedText(setupStage+' errno='+error?.errno+' '+(error?.message||String(error)))});throw error;}},
   onExit(exitCode){finish({success:exitCode===0,exitCode});},onAbort(error){factorySettled=true;finish({success:false,error:boundedText('actual runtime abort: '+error)});}};
  ownerModule=config;await createPython(config);factorySettled=true;
  if(retireRequested){retireOwned();return;}if(finalSent)return;
  let entry=data.code;
  if(data.argv){const encoded=data.argv.slice(1).map(value=>{let text='';for(const byte of value)text+=String.fromCharCode(byte);return btoa(text);});entry="import base64,os,sys,hyotan_runner; _hyotan_code=hyotan_runner.python_main([os.fsdecode(base64.b64decode(v)) for v in "+JSON.stringify(encoded)+"]); sys.stdout.flush();sys.stderr.flush();\nif not isinstance(_hyotan_code,int) or not -(2**31)<=_hyotan_code<2**31:raise RuntimeError('Python exit status outside native Int32 contract')\nraise SystemExit(_hyotan_code)";}
  ownerModule.callMain(['-c',entry]);
 }catch(error){factorySettled=true;if(retireRequested)retireOwned();else finish({success:false,error:boundedText(error)});}
};

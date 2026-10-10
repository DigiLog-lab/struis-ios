/* SPDX-License-Identifier: Apache-2.0 */
import {synchronousBroker,installWorkspace} from './filesystem.js';
onmessage=async e=>{
 const denials=[];
 try{
  if(!crossOriginIsolated||typeof SharedArrayBuffer!=='function')throw Error('isolated worker unavailable');
  if(typeof process!=='undefined'||typeof require!=='undefined')throw Error('native Node bridge forbidden');
  await import('./py/pyodide.js');
  const py=await globalThis.loadPyodide({indexURL:new URL('./py/',location.href).href});
  await py.loadPackage(['numpy','sympy','pyyaml']);
  if(e.data.argv){
   const response=await fetch('./hyotan_runner.py');if(!response.ok)throw Error('fixed Python runner unavailable');
   const source=await response.text();if(new TextEncoder().encode(source).length>65536)throw Error('runner asset budget');
   py.FS.writeFile('/lib/python3.14/site-packages/hyotan_runner.py',source);
   const {installBinaryStdio}=await import('./stdio.js');installBinaryStdio(py,e.data.stdio);
  }
  if(e.data.functionID===2){if(e.data.gitHistoryTestOnly!==true)throw Error('Git history test opt-in required');const {installGitHistory}=await import('./git/loader.js');await installGitHistory(py);}
  const broker=synchronousBroker(e.data.buffer);
  globalThis.virtualFSRequest=broker;
  installWorkspace(py,broker,denied=>{if(denials.length<16)denials.push(denied);});
  if(Object.keys(py.FS.filesystems).some(name=>name!=='MEMFS'))throw Error('native filesystem exports forbidden');
  let result,exitCode;
  if(e.data.argv){
   const argv=py.toPy(e.data.argv.slice(1));py.globals.set('_hyotan_command_bytes',argv);
   try{if(![1,2].includes(e.data.functionID))throw Error('unsupported trusted entry');const command=e.data.functionID===2?'import hyotan_virtual_git, os; hyotan_virtual_git.git_main':'import hyotan_runner, os; hyotan_runner.python_main';exitCode=await py.runPythonAsync(command+'([os.fsdecode(bytes(v)) for v in _hyotan_command_bytes])');await py.runPythonAsync('import sys; sys.stdout.flush(); sys.stderr.flush()');if(!Number.isInteger(exitCode)||exitCode<-(2**31)||exitCode>=2**31)throw Error('Python exit status outside native Int32 contract');result=exitCode;}finally{argv.destroy();py.globals.delete('_hyotan_command_bytes');}
  }else result=await py.runPythonAsync(e.data.code);
  postMessage({done:true,result:{success:exitCode===undefined||exitCode===0,value:String(result),...(exitCode===undefined?{}:{exitCode}),deniedOperations:denials,browser:{isolated:crossOriginIsolated,nativeBridge:false,filesystemBackends:Object.keys(py.FS.filesystems)}}});
 }catch(error){
  const deniedOperations=denials;
  const reasons=[...new Set(deniedOperations.map(item=>item.message))];
  const description=error?.name==='ErrnoError'?(error.message||'filesystem operation denied; use the permitted workspace'):String(error);
  postMessage({done:true,result:{success:false,...(e.data.argv?{exitCode:1}:{}),error:description+(reasons.length?'\nWorkspace operation denials observed during this invocation: '+reasons.join('; '):''),deniedOperations}});
 }
};

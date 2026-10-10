/* SPDX-License-Identifier: Apache-2.0 */
// Fixed test-only files; this loader never accepts a URL/root/entry from a guest.
const pins = {"hyotan_history.py": {"bytes": 5801, "sha256": "5f5ccdc16b450ed610631a271e027d5ad581e46a40eb3fc5c4a4eb25c48d4502"}, "hyotan_virtual_git.py": {"bytes": 486, "sha256": "21b77679e1697d3d35daa52c68e206c021fe300b580e235a276feabf5bab6b64"}, "packages.zip": {"bytes": 830309, "sha256": "2fae1c45e4b7f6894b8792d95c9c7286615b3d38262e421161701a485589dfb1"}};
async function fixed(name) {
 const response=await fetch(new URL(name,import.meta.url));
 if(!response.ok||response.redirected)throw Error('fixed Git asset unavailable');
 const expected=pins[name],length=Number(response.headers.get('Content-Length'));
 if(length!==expected.bytes)throw Error('fixed Git asset length');
 const bytes=await response.arrayBuffer();if(bytes.byteLength!==expected.bytes)throw Error('fixed Git asset length');
 const digest=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),b=>b.toString(16).padStart(2,'0')).join('');
 if(digest!==expected.sha256)throw Error('fixed Git asset digest');return bytes;
}
export async function installGitHistory(py) {
 const archive=await fixed('packages.zip');py.unpackArchive(archive,'zip',{extractDir:'/lib/python3.14/site-packages'});
 for(const name of ['hyotan_history.py','hyotan_virtual_git.py'])py.FS.writeFile('/lib/python3.14/site-packages/'+name,new Uint8Array(await fixed(name)));
}

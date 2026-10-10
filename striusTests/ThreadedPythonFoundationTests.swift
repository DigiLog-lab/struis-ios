// SPDX-License-Identifier: Apache-2.0
import XCTest
import Foundation
import Darwin
@testable import strius

/// Independent actual CLI pthread runtime probe; product and native provider stay off.
final class ThreadedPythonFoundationTests: XCTestCase {
    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    func testActualWKSyncThreadedMathCFileBoundaryCancellationRevocationAndFreshInstance() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_THREADED_PYTHON_LIVE"] == "1", "dedicated threaded foundation scheme is opt-in")
        let bundle = Bundle(for: Self.self)
        try XCTSkipUnless(bundle.url(forResource: "ThreadedPythonFoundationTestAssets", withExtension: nil) != nil,
            "STRUIS_THREADED_PYTHON_ASSETS_DIR is unset; the pinned experimental bundle is external")
        let assets = try await Task.detached { try ThreadedPythonFoundationAssets(bundle: bundle) }.value
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("threaded-foundation-" + UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace"), canary = base.appendingPathComponent("private/private-canary")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let privateBytes = Data("synthetic-private-canary".utf8); try privateBytes.write(to: canary)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"), withDestinationURL: canary)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("ancestor"), withDestinationURL: canary.deletingLastPathComponent())
        guard Darwin.link(canary.path, workspace.appendingPathComponent("hard").path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let fd = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }; defer { Darwin.close(fd) }
        let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-threaded-wk", generation: 501, access: .readWrite)
        let dispatcher = VirtualFilesystemDispatcher(broker: broker)
        let nonce = UUID().uuidString.lowercased()
        let origin = try VirtualFilesystemOrigin(fixedAssets: assets.files, dispatcher: dispatcher, python: "", nonce: nonce, commandBootstrap: Self.bootstrap(nonce: nonce, mode: "full"), provider: { Self.nativeCancelResponse($0, broker: broker) })
        defer { origin.stop() }
        let port = try await origin.start(), url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(nonce)/index.html"))
        let report = try await evaluate(url: url, nonce: nonce)
        XCTAssertEqual(report["success"] as? Bool, true, "Actual WK threaded runtime unsupported or failed: \(report["stage"] ?? "missing")")
        guard report["success"] as? Bool == true else { return }
        XCTAssertEqual(report["profile"] as? String, "sync-proxy-no-jspi");
        XCTAssertEqual(report["retirementRequested"] as? Bool, true); XCTAssertEqual(report["shared"] as? Bool, true)
        XCTAssertEqual(report["pthreadImport"] as? Bool, true)
        XCTAssertGreaterThan(report["mainHeartbeat"] as? Int ?? 0, 2)
        XCTAssertEqual(report["threads"] as? Int, 4)
        XCTAssertEqual(report["ctypes"] as? Bool, true)
        XCTAssertGreaterThan(dispatcher.operationCount, 50)
        XCTAssertEqual(try Data(contentsOf: canary), privateBytes)
        for index in 0..<4 {
            let handle = try broker.open("mixed-\(index).yaml", options: .read)
            XCTAssertGreaterThan(try broker.stat(handle).bytes, 0); try broker.close(handle)
        }
        // Cancellation has a separate fixed origin but the same trusted grant.
        // Its sole typed control endpoint can revoke this grant; it cannot mint one.
        let cancelNonce = UUID().uuidString.lowercased()
        let cancelOrigin = try VirtualFilesystemOrigin(fixedAssets: assets.files, dispatcher: dispatcher, python: "", nonce: cancelNonce, commandBootstrap: Self.bootstrap(nonce: cancelNonce, mode: "cancel"), provider: { Self.nativeCancelResponse($0, broker: broker) })
        defer { cancelOrigin.stop() }
        let cancelPort = try await cancelOrigin.start(), cancelURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(cancelPort)/\(cancelNonce)/index.html"))
        let cancelled = try await evaluate(url: cancelURL, nonce: cancelNonce)
        XCTAssertEqual(cancelled["success"] as? Bool, true, "Actual cancellation unconfirmed: \(cancelled["stage"] ?? "missing")")
        XCTAssertEqual(cancelled["nativeCancellationConfirmed"] as? Bool, true)
        XCTAssertEqual(cancelled["retirementRequested"] as? Bool, true)
        guard cancelled["success"] as? Bool == true, cancelled["nativeCancellationConfirmed"] as? Bool == true, cancelled["retirementRequested"] as? Bool == true else { return }
        XCTAssertThrowsError(try broker.open("mixed-0.yaml", options: .read)) { error in
            XCTAssertEqual((error as? WorkspaceOperationBroker.Failure)?.code, EACCES)
        }

        let denied = try await evaluate(url: url, nonce: nonce)
        XCTAssertEqual(denied["success"] as? Bool, false)
        XCTAssertEqual(denied["stage"] as? String, "runtime-denial")
        XCTAssertEqual(denied["denial"] as? Bool, true)
        guard denied["success"] as? Bool == false, denied["denial"] as? Bool == true, denied["stage"] as? String == "runtime-denial" else { return }
        let fresh = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: "trusted-threaded-next", generation: 502, access: .readWrite)
        let nextDispatcher = VirtualFilesystemDispatcher(broker: fresh), nextNonce = UUID().uuidString.lowercased()
        let nextOrigin = try VirtualFilesystemOrigin(fixedAssets: assets.files, dispatcher: nextDispatcher, python: "", nonce: nextNonce, commandBootstrap: Self.bootstrap(nonce: nextNonce, mode: "fresh"), provider: { Self.nativeCancelResponse($0, broker: fresh) })
        defer { nextOrigin.stop() }
        let nextPort = try await nextOrigin.start(), nextURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(nextPort)/\(nextNonce)/index.html"))
        let next = try await evaluate(url: nextURL, nonce: nextNonce)
        XCTAssertEqual(next["success"] as? Bool, true)
        XCTAssertEqual(next["retirementRequested"] as? Bool, true)
        let handle = try fresh.open("fresh.txt", options: .read); defer { try? fresh.close(handle) }
        XCTAssertEqual(try fresh.read(handle, offset: 0, count: 16), Data("fresh".utf8))
        XCTAssertEqual(try Data(contentsOf: canary), privateBytes)
        let attachment = XCTAttachment(string: "Actual WK synchronous no-JSPI profile/core pthread import/shared memory, four Python threads, matched native math and ctypes C boundary; descriptor requests=\(dispatcher.operationCount); trusted native cancellation confirmed=\(cancelled["nativeCancellationConfirmed"] as? Bool == true); revoked origin denied=\(denied["denial"] as? Bool == true); fresh success=\(next["success"] as? Bool == true). Synthetic only; PThread controller invoked with zero running/unused/pthread counts; Apple physical helper exit, physical memory and product integration unverified.")
        attachment.name = "Threaded Python foundation"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    private func evaluate(url: URL, nonce: String) async throws -> [String: Any] {
        let completed = expectation(description: "actual threaded WK runtime")
        let view = VirtualFilesystemView(url: url, nonce: nonce, completion: completed)
        defer { view.detach() }
        await fulfillment(of: [completed], timeout: 190)
        let report = view.reporter.report; await view.teardown()
        return try XCTUnwrap(report, "actual WK result missing; timeout is failure")
    }
    nonisolated private static func nativeCancelResponse(_ data: Data, broker: WorkspaceOperationBroker) -> Data {
        do {
            let request = try VirtualPythonProviderRequest(data)
            guard request.operation == "cancel" else { return Data(#"{"completed":false}"#.utf8) }
            try broker.revoke()
            return Data(#"{"completed":true}"#.utf8)
        } catch { return Data(#"{"completed":false}"#.utf8) }
    }
    private static func bootstrap(nonce: String, mode: String) -> String {
        """
        import {runVirtualPython} from './main.js';
        let heartbeat=0; const pulse=setInterval(()=>heartbeat++,5);
        const workers=new Set(),controllers=new Set(),W=globalThis.Worker,A=globalThis.AbortController;
        globalThis.Worker=class extends W{constructor(...args){super(...args);workers.add(this);}terminate(){workers.delete(this);super.terminate();}};
        globalThis.AbortController=class extends A{constructor(...args){super(...args);controllers.add(this);}};
        globalThis.filesystemTeardown=()=>{clearInterval(pulse);for(const c of controllers)c.abort();for(const w of workers)w.terminate();controllers.clear();workers.clear();};
        const send=value=>webkit.messageHandlers.filesystemResult.postMessage({nonce:'\(nonce)',mainHeartbeat:heartbeat,...value});
        const retirement=r=>{const p=r.pthreadRetirement;return p?.running===0&&p.unused===0&&p.pthreads===0&&p.controller==='actual Emscripten PThread.terminateAllThreads'&&p.terminationRequested===true;};
        const profile=r=>r.browser?.runtimeProfile==='sync-proxy-no-jspi'&&r.browser.optionalJSPIIOEnabled===false&&r.browser.nativeBridge===false;
        const nativeCancel=async()=>{const response=await fetch('./provider',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"operation":"cancel"}'});if(!response.ok||Number(response.headers.get('Content-Length'))>64)throw Error('native-cancel-transport');const reply=await response.json();if(reply.completed!==true)throw Error('native-cancel-rejected');return reply;};
        let stage='platform';
        try {
          if(!crossOriginIsolated||typeof SharedArrayBuffer!=='function')throw Error('unsupported-shared-isolation');
          const shared=new WebAssembly.Memory({initial:1,maximum:65536,shared:true}).buffer instanceof SharedArrayBuffer;
          stage='actual-core-compile';const core=await WebAssembly.compile(await(await fetch('./python.wasm')).arrayBuffer());
          const imports=WebAssembly.Module.imports(core);
          const pthreadImport=imports.some(x=>x.kind==='function'&&x.name==='__pthread_create_js');
          if(!shared||!pthreadImport||!imports.some(x=>x.kind==='memory'&&x.module==='env'))throw Error('actual-core-contract');
          // Browser APIs are never removed or replaced. Native loader verifies
          // the pinned compile-gated synchronous profile and source provenance.
          stage='actual-threaded-python';
          if('\(mode)'==='cancel'){
            stage='actual-cancellation';const abort=new AbortController();
            const pending=runVirtualPython("import threading\\nopen('/workspace/cancel-ready','w').write('ready')\\nthreading.Event().wait()",{signal:abort.signal,nativeCancel});
            let ready=false,readinessFailed=false;
            try{for(let i=0;i<250;i++){const response=await fetch('./broker',{method:'POST',headers:{'Content-Type':'application/json'},body:'{"sequence":777,"operation":"metadata","path":"cancel-ready"}'});if(!response.ok||Number(response.headers.get('Content-Length'))>65536)throw Error('readiness-transport');const value=await response.json();if(!value.errno&&value.metadata?.bytes===5){ready=true;break;}if(value.errno&&value.errno!=='ENOENT')throw Error('readiness-denied');await new Promise(done=>setTimeout(done,100));}}
            catch(error){readinessFailed=true;}finally{abort.abort();}
            const result=await pending;
            if(readinessFailed||!ready||result.cancelled!==true||result.exitCode!==130||result.nativeCancellationConfirmed!==true||!retirement(result))throw Error('cancel-unconfirmed');
            send({success:true,stage:'cancel-complete',nativeCancellationConfirmed:true,retirementRequested:true,shared,pthreadImport});
          }else{
            const scripts='\(mode)'==='full'?['foundation-thread-primitives.py','foundation-mixed.py','foundation-ctypes.py']:[];
            const code=scripts.length?(await Promise.all(scripts.map(async script=>await(await fetch('./'+script)).text()))).join('\\n'):"open('/workspace/fresh.txt','w').write('fresh')";
            const r=await runVirtualPython(code,{nativeCancel});
            if(!retirement(r))throw Error('retirement-unconfirmed');
            if(r.outputTruncated===true)throw Error('report-budget');
            if(!r.success){const denial=(r.deniedOperations||[]).some(x=>x.errno==='EACCES'&&typeof x.message==='string'&&x.message.includes('active workspace'));if(denial)stage='runtime-denial';throw Error('actual-runtime-failed');}
            if(!profile(r))throw Error('runtime-profile');
            let threads=0,ctypes=false;
            for(const line of r.output||[]){if(typeof line!=='string'||line.length>16384)throw Error('report-budget');try{const v=JSON.parse(line);if(v.mixed_math_threads===true&&Array.isArray(v.ids)&&new Set(v.ids).size===4)threads=4;if(v.native_guest_open_mediated===true&&v.private_denials===6)ctypes=true;}catch(e){if(e.message==='report-budget')throw e;}}
            send({success:true,stage:'complete',profile:'sync-proxy-no-jspi',retirementRequested:true,shared,pthreadImport,threads,ctypes});
          }
        } catch(error){send({success:false,stage,denial:stage==='runtime-denial'});}
        finally{globalThis.filesystemTeardown();}
        """
    }
    #endif
}

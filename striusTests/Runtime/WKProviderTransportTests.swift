// SPDX-License-Identifier: Apache-2.0
import XCTest
import Foundation
import Darwin
import UIKit
import WebKit
@testable import strius

#if DEBUG && targetEnvironment(simulator)
/// Immutable native authority; page envelopes contain only bytes/actions.
@MainActor private final class WKCapturedProvider {
    let host: NativeRuntimeHost
    let handle: NativeRuntimeHost.VirtualPythonCommandHandle
    let invocation: NativeVirtualPythonReply
    private var sequence: UInt64 = 1
    private var busy = false, sealed = false
    private var terminal: Int32?
    private var cancellation: Task<Bool, Never>?
    private(set) var observedOutput = false
    private(set) var observedBlockedInput = false
    init(host: NativeRuntimeHost, handle: NativeRuntimeHost.VirtualPythonCommandHandle, invocation: NativeVirtualPythonReply) {
        self.host = host; self.handle = handle; self.invocation = invocation
    }
    private func json(_ value: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{\"errno\":\"EIO\"}".utf8) }
    private func name(_ code: Int32) -> String {
        switch code { case EPIPE: return "EPIPE"; case EACCES, EPERM: return "EACCES"; case ECANCELED: return "ECANCELED"; case EINVAL: return "EINVAL"; default: return "EIO" }
    }
    func cancel() async -> Bool {
        if terminal != nil { return true } // An old completed origin cannot cancel a later invocation.
        sealed = true
        if let cancellation { return await cancellation.value }
        let task = Task { @MainActor in await host.cancelVirtualPythonTransportCommand(handle) }
        cancellation = task
        return await task.value
    }
    func execute(_ data: Data) async -> Data {
        do {
            let request = try VirtualPythonProviderRequest(data)
            if request.operation == "cancel" { return json(["completed": await cancel()]) }
            if request.operation == "finish", let terminal { return json(["completed": true, "exitCode": terminal]) }
            guard !sealed, !busy, sequence < UInt64.max else { return json(["errno": "EACCES"]) }
            busy = true; defer { busy = false }
            let current = sequence; sequence += 1
            if request.operation == "exchange" {
                let reply = try await host.virtualPythonControl(.init(action: .exchange, job: handle.job,
                    invocationID: invocation.invocationID, sequence: current, stdout: request.stdout,
                    stderr: request.stderr, stdinCapacity: request.capacity), for: handle)
                guard reply.stdoutAccepted >= 0, reply.stdoutAccepted <= request.stdout.count,
                      reply.stderrAccepted >= 0, reply.stderrAccepted <= request.stderr.count,
                      reply.stdin.count <= request.capacity else { throw WorkspaceOperationBroker.Failure(code: EIO) }
                if reply.stdoutAccepted > 0 { observedOutput = true }
                if observedOutput, request.capacity > 0, reply.stdin.isEmpty, !reply.stdinEOF { observedBlockedInput = true }
                var value: [String: Any] = ["stdin": reply.stdin.base64EncodedString(), "stdinEOF": reply.stdinEOF,
                    "stdoutAccepted": reply.stdoutAccepted, "stderrAccepted": reply.stderrAccepted]
                if reply.errorCode != 0 { value["errno"] = name(reply.errorCode) }
                return json(value)
            }
            sealed = true
            let reply = try await host.virtualPythonControl(.init(action: .finish, job: handle.job,
                invocationID: invocation.invocationID, sequence: current, stdinCapacity: 0, exitCode: request.exitCode), for: handle)
            // Native drain may have already completed with EPIPE before finish.
            guard [Int32(0), EPIPE, EAGAIN, EALREADY, EACCES].contains(reply.errorCode) else { throw WorkspaceOperationBroker.Failure(code: reply.errorCode) }
            let result = try await host.awaitVirtualPythonInvocationCompletion(invocation.invocationID, for: handle)
            terminal = result
            return json(["completed": true, "exitCode": result])
        } catch {
            // Never disclose XPC descriptions/private paths and never retry unknown ACKs.
            _ = await cancel()
            return json(["errno": "EIO", "completed": false])
        }
    }
}

@MainActor private final class WKProviderReporter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let url: URL, nonce: String
    let completion: XCTestExpectation
    var report: [String: Any]?
    init(url: URL, nonce: String, completion: XCTestExpectation) { self.url = url; self.nonce = nonce; self.completion = completion }
    private func finish(_ value: [String: Any]) { guard report == nil else { return }; report = value; completion.fulfill() }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "http",
              message.frameInfo.securityOrigin.host == "127.0.0.1", message.frameInfo.securityOrigin.port == url.port,
              let value = message.body as? [String: Any], value["nonce"] as? String == nonce else { finish(["success": false]); return }
        finish(value)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url == url ? .allow : .cancel) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(["success": false]) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(["success": false]) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(["success": false]) }
}

/// A dead WebContent process cannot strand lifecycle teardown.
@MainActor private final class WKProviderCleanupEvaluation {
    private var continuation: CheckedContinuation<Bool, Never>?
    private func finish(_ value: Bool) { let pending = continuation; continuation = nil; pending?.resume(returning: value) }
    func run(in view: WKWebView) async -> Bool {
        await withCheckedContinuation { pending in
            continuation = pending
            view.evaluateJavaScript("globalThis.filesystemTeardown?.(); true") { [weak self] value, error in
                let success = error == nil && (value as? Bool == true)
                Task { @MainActor in self?.finish(success) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                self?.finish(false)
            }
        }
    }
}

/// Actual WK CPython -> captured XPC -> real native dash; product route stays off.
final class WKProviderTransportTests: XCTestCase {
    @MainActor private func discover(_ host: NativeRuntimeHost, _ handle: NativeRuntimeHost.VirtualPythonCommandHandle) async throws -> NativeVirtualPythonReply {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let reply = try await host.virtualPythonControl(.init(action: .discover, job: handle.job), for: handle)
            if reply.errorCode == 0, reply.invocationID != 0 { return reply }
            guard reply.errorCode == EAGAIN else { throw WorkspaceOperationBroker.Failure(code: reply.errorCode) }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WorkspaceOperationBroker.Failure(code: ETIMEDOUT)
    }
    @MainActor private func runWK(assets: VirtualFilesystemAssets, workspace: URL, provider: WKCapturedProvider, cancelAfter: Int? = nil, gitHistoryAssets: VirtualGitHistoryAssets? = nil) async throws -> [String: Any] {
        try await runWK(fixedAssets: assets.files, workspace: workspace, provider: provider, cancelAfter: cancelAfter, gitHistoryAssets: gitHistoryAssets)
    }
    @MainActor private func runWK(fixedAssets: [String: Data], threaded: Bool = false, workspace: URL, provider: WKCapturedProvider, cancelAfter: Int? = nil, gitHistoryAssets: VirtualGitHistoryAssets? = nil) async throws -> [String: Any] {
        guard [UInt32(1), UInt32(2)].contains(provider.invocation.function), (provider.invocation.function == 2) == (gitHistoryAssets != nil), !threaded || provider.invocation.function == 1 else { throw WorkspaceOperationBroker.Failure(code: EINVAL) }
        let fd = Darwin.open(workspace.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw WorkspaceOperationBroker.Failure(code: errno) }; defer { Darwin.close(fd) }
        let broker = try WorkspaceOperationBroker(trustedDirectoryFD: fd, owner: provider.handle.job.owner,
            generation: provider.handle.job.generation, access: gitHistoryAssets == nil ? .readWrite : .readOnly)
        let dispatcher = VirtualFilesystemDispatcher(broker: broker)
        defer { dispatcher.stop() }
        let nonce = UUID().uuidString.lowercased()
        let args = String(decoding: try JSONSerialization.data(withJSONObject: provider.invocation.argv.map { $0.base64EncodedString() }), as: UTF8.self)
        let token = String(decoding: try JSONSerialization.data(withJSONObject: nonce, options: [.fragmentsAllowed]), as: UTF8.self)
        let cancel = cancelAfter != nil ? "setTimeout(()=>abort.abort(),\(threaded ? 30000 : 15000));" : ""
        let trigger = cancelAfter.map { "if(readyAccepted&&!cancelScheduled&&x.stdinCapacity>0&&r.stdin===''&&!r.stdinEOF){cancelScheduled=true;setTimeout(()=>abort.abort(),\($0));}if(r.stdoutAccepted>0)readyAccepted=true;" } ?? ""
        let retirementGate = threaded ? "const p=result.pthreadRetirement;if(p?.running!==0||p.unused!==0||p.pthreads!==0||p.controller!=='actual Emscripten PThread.terminateAllThreads'||p.terminationRequested!==true)throw Error('retirement');if(result.cancelled&&result.nativeCancellationConfirmed!==true)throw Error('native cancel');if(!result.cancelled&&result.browser?.runtimeProfile!=='sync-proxy-no-jspi')throw Error('profile');" : ""
        let reportBody = threaded ? "{nonce:\(token),success:result.success,exitCode:result.exitCode,cancelled:result.cancelled===true,nativeCancellationConfirmed:result.nativeCancellationConfirmed===true,pthreadRetirementConfirmed:true}" : "{nonce:\(token),...result}"
        let bootstrap = """
        import {runVirtualPythonCommand} from './main.js';
        const workers=new Set(), controllers=new Set(), NativeWorker=globalThis.Worker, NativeAbort=globalThis.AbortController;
        globalThis.Worker=class extends NativeWorker {constructor(...args){super(...args);workers.add(this);}terminate(){workers.delete(this);super.terminate();}};
        globalThis.AbortController=class extends NativeAbort {constructor(...args){super(...args);controllers.add(this);}};
        const from64=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
        const to64=b=>{let s='';for(const x of b)s+=String.fromCharCode(x);return btoa(s);};
        const abort=new AbortController(); let calls=0,cancelScheduled=false,readyAccepted=false;
        const call=async body=>{if(++calls>900)throw Error('request budget');const response=await fetch('provider',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});if(!response.ok)throw Error('transport');return response.json();};
        const provider={functionID:\(provider.invocation.function),
          exchange:async x=>{const r=await call({operation:'exchange',stdout:to64(x.stdoutData),stderr:to64(x.stderrData),capacity:x.stdinCapacity});\(trigger)return {...r,stdinData:from64(r.stdin||'')};},
          finish:exitCode=>call({operation:'finish',exitCode:String(exitCode)}),cancel:()=>call({operation:'cancel'})};
        globalThis.filesystemTeardown=()=>{for(const c of controllers)c.abort();controllers.clear();for(const w of workers)w.terminate();workers.clear();}; \(cancel)
        try{const result=await runVirtualPythonCommand(\(args).map(from64),provider,{signal:abort.signal,gitHistoryTestOnly:\(gitHistoryAssets != nil ? "true" : "false")});\(retirementGate)webkit.messageHandlers.filesystemResult.postMessage(\(reportBody));}
        catch(error){webkit.messageHandlers.filesystemResult.postMessage({nonce:\(token),success:false,cancelled:abort.signal.aborted,error:'provider command failed'});}
        """
        let origin = try VirtualFilesystemOrigin(fixedAssets: fixedAssets, dispatcher: dispatcher, python: "", nonce: nonce,
            commandBootstrap: bootstrap, gitHistoryAssets: gitHistoryAssets, provider: { data in
                if threaded, let request = try? VirtualPythonProviderRequest(data), request.operation == "cancel" {
                    do { try broker.revoke() }
                    catch { _ = await provider.cancel(); return Data(#"{"completed":false}"#.utf8) }
                }
                return await provider.execute(data)
            })
        defer { origin.stop() }
        let port = try await origin.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(nonce)/index.html"))
        let done = expectation(description: "real WK/native provider")
        let reporter = WKProviderReporter(url: url, nonce: nonce, completion: done)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController.add(reporter, name: "filesystemResult")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config); view.navigationDelegate = reporter
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window = UIWindow(windowScene: scene) } else { window = UIWindow(frame: view.frame) }
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(view); window.isHidden = false
        view.load(URLRequest(url: url))
        await fulfillment(of: [done], timeout: threaded ? 90 : 25)
        // Native cleanup is awaited before the immutable origin/broker disappear.
        dispatcher.stop() // Revoke FS before waking/cancelling old guest continuations.
        let cleanup = await provider.cancel()
        _ = await WKProviderCleanupEvaluation().run(in: view)
        view.stopLoading(); config.userContentController.removeScriptMessageHandler(forName: "filesystemResult"); view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil); view.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil; origin.stop()
        XCTAssertTrue(cleanup, "Native cleanup/retirement must be confirmed")
        let report = try XCTUnwrap(reporter.report, "Missing WK report is failure")
        if threaded {
            guard cleanup else { throw WorkspaceOperationBroker.Failure(code: EIO) }
            guard report["pthreadRetirementConfirmed"] as? Bool == true else { throw WorkspaceOperationBroker.Failure(code: EIO) }
            if cancelAfter != nil {
                guard report["nativeCancellationConfirmed"] as? Bool == true else { throw WorkspaceOperationBroker.Failure(code: EIO) }
            }
        }
        return report
    }

    @MainActor func testActualWKPythonNativePipelineMathFilesCancellationAndFreshInvocation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_VIRTUAL_PYTHON_LIVE"] == "1", "dedicated live composition only")
        try XCTSkipUnless(Bundle(for: Self.self).url(forResource: "VirtualPythonTestAssets", withExtension: nil) != nil,
            "VirtualPythonTestAssets are absent; run prepare-virtual-python-test-assets.py before building")
        let assets = try VirtualFilesystemAssets(bundle: Bundle(for: Self.self))
        try await runNativeComposition(fixedAssets: assets.files, threaded: false)
    }
    @MainActor func testActualWKThreadedPythonCapturedNativePipelineCancellationAndFreshInvocation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_THREADED_PYTHON_LIVE"] == "1", "dedicated threaded composition only")
        let bundle = Bundle(for: Self.self)
        try XCTSkipUnless(bundle.url(forResource: "ThreadedPythonFoundationTestAssets", withExtension: nil) != nil,
            "STRUIS_THREADED_PYTHON_ASSETS_DIR is unset; the pinned experimental bundle is external")
        let assets = try await Task.detached { try ThreadedPythonCommandAssets(bundle: bundle) }.value
        try await runNativeComposition(fixedAssets: assets.files, threaded: true)
    }
    @MainActor private func runNativeComposition(fixedAssets: [String: Data], threaded: Bool) async throws {
        let boot = HyotanBoot(); await boot.start(); XCTAssertTrue(boot.state.isReady)
        let host = NativeRuntimeHost.shared
        if let root = NativeRuntimePaths.sharedRoot { try FileManager.default.createDirectory(at: root.deletingLastPathComponent().appendingPathComponent("Library"), withIntermediateDirectories: true) }
        _ = try await host.start(onExit: { _ in }); defer { host.stop() }
        let workspace = HyotanBoot.workspaceRoot.appendingPathComponent("wk-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let bytes = Data((0..<(65536 * 5 + 237)).map { UInt8(($0 * 37) % 251) })
        try bytes.write(to: workspace.appendingPathComponent("input.bin"))
        let threadedSource = threaded ? "sys.path[:0]=['/lib/site-packages','/lib/sympy.whl','/lib/mpmath.whl']" : ""
        let threadedMath = threaded ? """
        import threading,os
        ids=[];lock=threading.Lock();barrier=threading.Barrier(5);failures=[]
        def compute(i):
            try:
                barrier.wait(timeout=20)
                assert np.allclose(np.linalg.solve([[3.,1.],[1.,2.]],[9.,8.]),[2.,3.])
                assert str(sp.integrate(sp.Symbol('x')**2,(sp.Symbol('x'),0,3)))=='9'
                text=yaml.safe_dump({'thread':i,'ok':True})
                with open('/workspace/thread-%d.tmp'%i,'w') as f:f.write(text)
                os.replace('/workspace/thread-%d.tmp'%i,'/workspace/thread-%d.yaml'%i)
                with lock:
                    ids.append(threading.get_ident())
                    sys.stderr.buffer.write(b'THREADED_STDIO'+bytes([10]));sys.stderr.buffer.flush()
            except BaseException as e:
                with lock:failures.append(type(e).__name__)
        threads=[threading.Thread(target=compute,args=(i,)) for i in range(4)]
        for t in threads:t.start()
        barrier.wait(timeout=20)
        for t in threads:t.join(timeout=20)
        assert not any(t.is_alive() for t in threads) and not failures and len(set(ids))==4
        """ : ""
        let extraMath = threaded ? ",'thread_ids':len(set(ids))" : ""
        let script = """
        import sys, json
        \(threadedSource)
        assert sys.argv[1] == '日本語'
        first=sys.stdin.buffer.read(1024)
        sys.stdout.buffer.write(bytes(x^0x55 for x in first));sys.stdout.buffer.flush()
        sys.stderr.buffer.write(bytes(x^0xaa for x in first));sys.stderr.buffer.flush()
        while True:
            b=sys.stdin.buffer.read(16384)
            if not b:break
            sys.stdout.buffer.write(bytes(x^0x55 for x in b));sys.stdout.buffer.flush()
            sys.stderr.buffer.write(bytes(x^0xaa for x in b));sys.stderr.buffer.flush()
        import numpy as np, sympy as sp, yaml
        \(threadedMath)
        solved=np.linalg.solve(np.array([[3.,1.],[1.,2.]]),np.array([9.,8.])).tolist()
        assert np.allclose(solved,[2.0,3.0],rtol=0,atol=1e-12)
        solved=np.round(solved,12).tolist()
        with open('/workspace/日本語.json','w') as f:json.dump({'solve':solved,'integral':str(sp.integrate(sp.Symbol('x')**2,(sp.Symbol('x'),0,3))),'yaml':yaml.safe_load('ok: true')['ok']\(extraMath)},f)
        sys.exit(42)
        """
        try Data(script.utf8).write(to: workspace.appendingPathComponent("work.py"))
        // Native commands share process-wide BSD getopt state. The flags keep
        // option parsing in the two stages from overlapping: the consumer's
        // head starts after the producer's head, and tee creates early.flag
        // only after parsing, before the producer starts tail.
        let command = "{ head -c 1024 input.bin; : >producer.head; i=0; while [ ! -f early.flag ] && [ \"$i\" -lt \(threaded ? 400 : 200) ]; do sleep 0.1; i=$((i+1)); done; [ -f early.flag ] || exit 91; tail -c +1025 input.bin; : >producer.done; } | python3 work.py 日本語 2>errors.bin | { i=0; while [ ! -f producer.head ] && [ \"$i\" -lt \(threaded ? 400 : 200) ]; do sleep 0.1; i=$((i+1)); done; head -c 1024 >first.bin; if [ -f producer.done ]; then printf late >timing; else printf early >timing; fi; tee early.flag >rest.bin; }"
        let handle = try await host.beginVirtualPythonTransportCommand(command: command, cwd: workspace.path, owner: "wk-pipeline-" + UUID().uuidString)
        do {
            let invocation = try await discover(host, handle); XCTAssertEqual(invocation.function, 1)
            let report = try await runWK(fixedAssets: fixedAssets, threaded: threaded, workspace: workspace, provider: WKCapturedProvider(host: host, handle: handle, invocation: invocation))
            XCTAssertEqual(report["exitCode"] as? Int, 42)
            _ = try await host.finishVirtualPythonTransportCommand(handle)
            let first = try Data(contentsOf: workspace.appendingPathComponent("first.bin")), rest = try Data(contentsOf: workspace.appendingPathComponent("rest.bin"))
            XCTAssertEqual(first + rest, Data(bytes.map { $0 ^ 0x55 }))
            let childStderr = threaded ? Data(String(repeating: "THREADED_STDIO\n", count: 4).utf8) : Data()
            XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("errors.bin")), Data(bytes.map { $0 ^ 0xaa }) + childStderr)
            XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("timing"), encoding: .utf8), "early")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: workspace.appendingPathComponent("日本語.json"))) as? [String: Any]
            XCTAssertEqual(saved?["solve"] as? [Double], [2,3]); XCTAssertEqual(saved?["integral"] as? String, "9"); XCTAssertEqual(saved?["yaml"] as? Bool, true)
            if threaded {
                XCTAssertEqual(saved?["thread_ids"] as? Int, 4)
                for index in 0..<4 { XCTAssertTrue(try String(contentsOf: workspace.appendingPathComponent("thread-\(index).yaml"), encoding: .utf8).contains("ok: true")) }
            }
        } catch { printVirtualPythonProviderDiagnostics(); _ = await host.cancelVirtualPythonTransportCommand(handle); _ = try? await host.finishVirtualPythonTransportCommand(handle); throw error }
        // Cancellation blocks on real native stdin, then a fresh WK invocation succeeds.
        for cancelled in [true, false] {
            let code = cancelled ? "import sys;sys.stdout.buffer.write(b\"READY\");sys.stdout.buffer.flush();sys.stdin.buffer.read()" : "import sys;assert sys.argv[1]=='日本語';print('FRESH_WK_NATIVE');sys.exit(42)"
            let cmd = cancelled ? "{ i=0; while [ ! -f stop.input ] && [ \"$i\" -lt 400 ]; do sleep 0.1; i=$((i+1)); done; } | python3 -c '\(code)'" : "python3 -c \"\(code)\" 日本語 >fresh.bin"
            let next = try await host.beginVirtualPythonTransportCommand(command: cmd, cwd: workspace.path, owner: "wk-next-" + UUID().uuidString)
            do {
                let invocation = try await discover(host, next)
                let provider = WKCapturedProvider(host: host, handle: next, invocation: invocation)
                let report = try await runWK(fixedAssets: fixedAssets, threaded: threaded, workspace: workspace, provider: provider, cancelAfter: cancelled ? 200 : nil)
                if cancelled { XCTAssertTrue(provider.observedOutput, "CPython must execute before cancellation"); XCTAssertTrue(provider.observedBlockedInput, "READY must be acknowledged before a real empty non-EOF input request"); XCTAssertEqual(report["cancelled"] as? Bool, true); _ = try? await host.finishVirtualPythonTransportCommand(next) }
                else { XCTAssertEqual(report["exitCode"] as? Int, 42); let reply = try await host.finishVirtualPythonTransportCommand(next); XCTAssertEqual(reply.exitCode, 42); XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("fresh.bin"), encoding: .utf8), "FRESH_WK_NATIVE\n") }
            } catch { printVirtualPythonProviderDiagnostics(); _ = await host.cancelVirtualPythonTransportCommand(next); _ = try? await host.finishVirtualPythonTransportCommand(next); throw error }
        }
    }
    /// Trusted synthetic loose objects: actual native git entry -> WK/Dulwich -> broker.
    @MainActor func testActualWKNativeGitHistoryJapaneseDenialAndFreshInvocation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1" && ProcessInfo.processInfo.environment["STRUIS_VIRTUAL_PYTHON_LIVE"] == "1", "dedicated live Git composition only")
        try XCTSkipUnless(Bundle(for: Self.self).url(forResource: "VirtualPythonTestAssets", withExtension: nil) != nil,
            "VirtualPythonTestAssets are absent; run prepare-virtual-python-test-assets.py before building")
        let assets = try VirtualFilesystemAssets(bundle: Bundle(for: Self.self))
        try XCTSkipUnless(Bundle(for: Self.self).url(forResource: "VirtualPythonGitTestAssets", withExtension: nil) != nil,
            "VirtualPythonGitTestAssets are absent; run prepare-virtual-git-test-assets.py before building")
        let gitAssets = try VirtualGitHistoryAssets(bundle: Bundle(for: Self.self)) // Missing/corrupt assets fail.
        let boot = HyotanBoot(); await boot.start(); XCTAssertTrue(boot.state.isReady)
        let host = NativeRuntimeHost.shared
        if let root = NativeRuntimePaths.sharedRoot { try FileManager.default.createDirectory(at: root.deletingLastPathComponent().appendingPathComponent("Library"), withIntermediateDirectories: true) }
        _ = try await host.start(onExit: { _ in }); defer { host.stop() }
        let base = HyotanBoot.workspaceRoot.appendingPathComponent("wk-git-fixture-" + UUID().uuidString)
        let workspace = base.appendingPathComponent("workspace"), canary = base.appendingPathComponent("synthetic-private-canary")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let privateBytes = Data("synthetic private Git canary".utf8); try privateBytes.write(to: canary)
        let objects: [String: String] = [
            "802c1b509c861abbb5024f6a19c1b928c32b7cb1": "eJxLyslPUjA0ZHiyf+6znkauF8tWcQEAT24IoQ==",
            "c3f0c88241e89835b0120f703a8292a59f75b81b": "eJwBMQDO/3RyZWUgNDEAMTAwNjQ0IOaXpeacrOiqni50eHQAgCwbUJyGGru1Ak9qGcG5KMMrfLHRrhPn",
            "d4d3c192095c5942e7e036a3ea32f6ed6f755ab8": "eJyVjUsOAiEQBV1zCvYmho8ESMzEtUtv0GATO4Fhgj1mju8nXsC3qF3Vy701Yqm93/FAlNkWlUMwR40hBuuS0kYVrywEEw24WLxLQScBK9/7kNfeWZ4KbbwOPOMGbal4oPkJlW7Tu6t+k/sPRf7+Mf5vCpqJCaq8wAIzPlC8AAfJOYo=",
            "a34f3c9c9d343b404db7fba25dbdc0ac439c3752": "eJxLyslPUjC0YHiyf+6znkaup2sncL3Yv/dp1wIuAKCbDQ8=",
            "6b4ebb40cbb1155c2b7db51b434152fa2b845991": "eJwBMQDO/3RyZWUgNDEAMTAwNjQ0IOaXpeacrOiqni50eHQAo088nJ00O0BNt/uiXb3ArEOcN1Lj9RU4",
            "56888d6779662ee75770a981961d6b239588bd8e": "eJydjkkKAjEQAD3nFbkLkq0TAyI+wS90Jx1nYDZiRub5MoofsE51Kag0j2PfpDHh0Cqz9OSYyKlEpDVAMhQygSZnnQZT0NDZQYxaLFh5ajK7bJOORkVIEJ3hwMp6tIzWFM/ZlwCAdBa4tm6u8v7NLqXf2lr5xhuOy8Cnfnrh0Oer1EHtaKXkcReRPoeN/2l/l6nD6cFP8QZ8CUi4",
            "9a807e572d15d8c62646532470dbfb55020f9706": "eJwBIQDe/2Jsb2IgMjUA5L+d5oyBCuWtkArov73liqAK5pyr5bC+ChBREZc=",
            "52aa5fe8e30283fbec234b7214276811166af366": "eJwBMQDO/3RyZWUgNDEAMTAwNjQ0IOaXpeacrOiqni50eHQAmoB+Vy0V2MYmRlMkcNv7VQIPlwbauxOO",
            "17ce6f96bdae6bd9f1b549c7f96e131b2b5b0600": "eJydjksKwyAQQLv2FO4LRcc4TqCUQk8y0ZEI+SGm5PglOULf6m0evLjOc2kawN1aFdEemH0WEmeAXB4kguuGALaDgGStReTsENXGVZamPRJRwhB6RBAJPgTDPdkebcIBXO+JhkSieG/jWvVnLFPSz1yOtld5y8HzNsmjLF+eSnppG8wJGKPvp6h4DTb5I1XxKnjbZEnqBz+XRVY=",
        ]
        for (sha, encoded) in objects {
            let location = workspace.appendingPathComponent(".git/objects/" + String(sha.prefix(2)) + "/" + String(sha.dropFirst(2)))
            try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(Data(base64Encoded: encoded)).write(to: location)
        }
        let refs = workspace.appendingPathComponent(".git/refs/heads")
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        try Data("17ce6f96bdae6bd9f1b549c7f96e131b2b5b0600\n".utf8).write(to: refs.appendingPathComponent("main"))
        try Data("ref: refs/heads/main\n".utf8).write(to: workspace.appendingPathComponent(".git/HEAD"))
        // Deliberately do not provide host/user config, hooks, alternates or network.
        let tracked = workspace.appendingPathComponent("日本語.txt"), contents = Data("保持\n子\n追加\n末尾\n".utf8)
        try contents.write(to: tracked)
        for phase in 0..<4 {
            let isLog = phase == 0, denied = phase == 2
            if denied { try FileManager.default.removeItem(at: tracked); try FileManager.default.createSymbolicLink(at: tracked, withDestinationURL: canary) }
            if phase == 3 { try FileManager.default.removeItem(at: tracked); try contents.write(to: tracked) }
            let destination = "git-output-\(phase).txt"
            let command = (isLog ? "git log" : "git blame 日本語.txt") + " >" + destination
            let handle = try await host.beginVirtualPythonTransportCommand(command: command, cwd: workspace.path, owner: "wk-git-" + UUID().uuidString)
            do {
                let invocation = try await discover(host, handle)
                XCTAssertEqual(invocation.function, 2)
                XCTAssertEqual(invocation.argv.map { String(decoding: $0, as: UTF8.self) }, isLog ? ["git", "log"] : ["git", "blame", "日本語.txt"])
                let report = try await runWK(assets: assets, workspace: workspace, provider: WKCapturedProvider(host: host, handle: handle, invocation: invocation), gitHistoryAssets: gitAssets)
                let reply = try await host.finishVirtualPythonTransportCommand(handle)
                XCTAssertEqual(report["exitCode"] as? Int, denied ? 1 : 0)
                XCTAssertEqual(reply.exitCode, denied ? 1 : 0)
                let output = try String(contentsOf: workspace.appendingPathComponent(destination), encoding: .utf8)
                if denied {
                    let reasons = try XCTUnwrap(report["deniedOperations"] as? [[String: Any]])
                    XCTAssertFalse(reasons.isEmpty)
                    XCTAssertTrue(reasons.allSatisfy { Set($0.keys) == Set(["operation", "errno", "message"]) && $0["errno"] as? String == "EACCES" && ($0["message"] as? String)?.contains("active workspace") == true })
                    XCTAssertFalse(String(describing: reasons).contains(canary.path))
                    XCTAssertTrue(output.isEmpty)
                } else if isLog {
                    for sha in ["17ce6f96bdae6bd9f1b549c7f96e131b2b5b0600", "56888d6779662ee75770a981961d6b239588bd8e", "d4d3c192095c5942e7e036a3ea32f6ed6f755ab8"] { XCTAssertTrue(output.contains(sha)) }
                    XCTAssertTrue(output.contains("child append")); XCTAssertTrue(output.contains("parent changes"))
                } else {
                    let lines = output.split(separator: "\n").map(String.init)
                    XCTAssertEqual(lines.count, 4)
                    guard lines.count == 4 else { throw WorkspaceOperationBroker.Failure(code: EIO) }
                    XCTAssertTrue(lines[0].hasPrefix("^d4d3c19") && lines[0].contains("Root") && lines[0].hasSuffix("保持"))
                    XCTAssertTrue(lines[1].hasPrefix("56888d67") && lines[1].contains("Parent") && lines[1].hasSuffix("子"))
                    XCTAssertTrue(lines[2].hasPrefix("56888d67") && lines[2].contains("Parent") && lines[2].hasSuffix("追加"))
                    XCTAssertTrue(lines[3].hasPrefix("17ce6f96") && lines[3].contains("Child") && lines[3].hasSuffix("末尾"))
                }
                XCTAssertEqual(try Data(contentsOf: canary), privateBytes)
                print("WK_NATIVE_GIT_HISTORY phase=\(phase) function=2 actual_cpython=true exit=\(reply.exitCode) canary_unchanged=true")
            } catch { printVirtualPythonProviderDiagnostics(); _ = await host.cancelVirtualPythonTransportCommand(handle); _ = try? await host.finishVirtualPythonTransportCommand(handle); throw error }
        }
    }

}
#endif

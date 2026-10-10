import XCTest
import UIKit
import Network
import WebKit

/// Test-owned origin: fixed in-memory assets, no filesystem or application data.
nonisolated private final class VirtualPythonPlatformOrigin: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "virtual-python.platform-origin")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var accepted = 0
    private var stopped = false
    private var pendingStart: CheckedContinuation<UInt16, Error>?
    private let assets: [String: (String, Data)]
    let nonce: String

    init(nonce: String) throws {
        self.nonce = nonce
        let prefix = "/\(nonce)/"
        let html = "<!doctype html><meta charset=utf-8><pre id=result>RUNNING</pre><script src=main.js></script>"
        let main = "globalThis.platformNonce='\(nonce)';\n" + VirtualPythonPlatformAssets.main
        assets = [prefix + "index.html": ("text/html; charset=utf-8", Data(html.utf8)),
                  prefix + "main.js": ("application/javascript", Data(main.utf8)),
                  prefix + "worker.js": ("application/javascript", Data(VirtualPythonPlatformAssets.worker.utf8))]
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    private func resolveStart(_ result: Result<UInt16, Error>) {
        lock.lock()
        let continuation = pendingStart
        pendingStart = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingStart = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port { self.resolveStart(.success(port.rawValue)) }
                    else { self.resolveStart(.failure(URLError(.cannotConnectToHost))) }
                case .failed(let error), .waiting(let error): self.resolveStart(.failure(error))
                case .cancelled: self.resolveStart(.failure(URLError(.cancelled)))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.resolveStart(.failure(URLError(.timedOut)))
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let active = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        resolveStart(.failure(URLError(.cancelled)))
        listener.cancel()
        active.forEach { $0.cancel() }
    }

    private func finish(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        connection.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard !stopped, accepted < 16, connections.count < 8 else {
            lock.unlock(); connection.cancel(); return
        }
        accepted += 1
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.finish(connection)
        }
        receive(connection, header: Data())
    }

    private func receive(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var next = header
            if let data { next.append(data) }
            guard error == nil, next.count <= 4096 else { self.finish(connection); return }
            guard let end = next.range(of: Data("\r\n\r\n".utf8)) else {
                guard !complete else { self.finish(connection); return }
                self.receive(connection, header: next); return
            }
            guard end.upperBound == next.endIndex,
                  let text = String(data: next[..<end.lowerBound], encoding: .ascii) else {
                self.finish(connection); return
            }
            let lines = text.components(separatedBy: "\r\n")
            let request = (lines.first ?? "").split(separator: " ")
            guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1",
                  let asset = self.assets[String(request[1])],
                  let port = self.listener.port else { self.finish(connection); return }
            var hosts: [String] = []
            for line in lines.dropFirst() {
                let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { self.finish(connection); return }
                let key = pair[0].lowercased()
                let value = pair[1].trimmingCharacters(in: .whitespaces)
                if key == "host" { hosts.append(value) }
                if key == "transfer-encoding" || (key == "content-length" && value != "0") {
                    self.finish(connection); return
                }
            }
            guard hosts == ["127.0.0.1:\(port.rawValue)"] else { self.finish(connection); return }
            let responseHeader = "HTTP/1.1 200 OK\r\nContent-Type: \(asset.0)\r\nContent-Length: \(asset.1.count)\r\nConnection: close\r\nCache-Control: no-store\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Embedder-Policy: require-corp\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: default-src 'none'; script-src 'self'; worker-src 'self'; connect-src 'none'\r\nX-Content-Type-Options: nosniff\r\n\r\n"
            var response = Data(responseHeader.utf8)
            response.append(asset.1)
            connection.send(content: response, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.finish(connection)
            })
        }
    }
}

@MainActor
private final class VirtualPythonPlatformReporter: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let expectedURL: URL
    let nonce: String
    let completion: XCTestExpectation
    var report: [String: Any]?
    private var finished = false

    init(url: URL, nonce: String, completion: XCTestExpectation) {
        expectedURL = url; self.nonce = nonce; self.completion = completion
    }

    private func finish(_ report: [String: Any]) {
        guard !finished else { return }
        finished = true; self.report = report; completion.fulfill()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "127.0.0.1",
              message.frameInfo.securityOrigin.port == (expectedURL.port ?? -1),
              let body = message.body as? [String: Any], body["nonce"] as? String == nonce else {
            finish(["success": false, "error": "invalid platform result envelope"]); return
        }
        finish(body)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url == expectedURL ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(["success": false, "error": "WK navigation failed"])
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(["success": false, "error": "WK provisional navigation failed"])
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(["success": false, "error": "WK content process terminated"])
    }
}

/// Await guest cleanup without hanging on a terminated WebContent process.
@MainActor
private final class VirtualPythonPlatformTeardown {
    private var pending: CheckedContinuation<Bool, Never>?
    private func finish(_ executed: Bool) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: executed)
    }
    func perform(_ webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            pending = continuation
            webView.evaluateJavaScript("globalThis.platformTeardown?.(); true") { [weak self] _, error in
                let executed = error == nil
                Task { @MainActor in self?.finish(executed) }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 750_000_000)
                self?.finish(false)
            }
        }
    }
}

final class VirtualPythonPlatformTests: XCTestCase {
    #if DEBUG && targetEnvironment(simulator)
    @MainActor
    func testOwnedLoopbackWorkerSupportsBoundedDuplexAndCancellation() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRUIS_NATIVE_LIVE"] == "1", "live Simulator platform test is opt-in")
        let nonce = UUID().uuidString.lowercased()
        let origin = try VirtualPythonPlatformOrigin(nonce: nonce)
        defer { origin.stop() }
        let port = try await origin.start()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(nonce)/index.html"))
        let completed = expectation(description: "real WK platform result")
        let reporter = VirtualPythonPlatformReporter(url: url, nonce: nonce, completion: completed)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(reporter, name: "platformResult")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.navigationDelegate = reporter
        // Test-owned visible view, without taking key-window ownership.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        }
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(webView)
        window.isHidden = false
        defer {
            webView.evaluateJavaScript("globalThis.platformTeardown?.()", completionHandler: nil)
            webView.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "platformResult")
            webView.navigationDelegate = nil
            webView.loadHTMLString("<!doctype html><title>terminated</title>", baseURL: nil)
            webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
        }
        webView.load(URLRequest(url: url))
        await fulfillment(of: [completed], timeout: 25)
        let teardown = VirtualPythonPlatformTeardown()
        let cleanupExecuted = await teardown.perform(webView)
        origin.stop()
        print("VIRTUAL_PYTHON_PLATFORM_TEARDOWN executed=\(cleanupExecuted)")
        let report = try XCTUnwrap(reporter.report, "WK capability result missing; unsupported/timeout is a failure")
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("VIRTUAL_PYTHON_PLATFORM \(String(decoding: json, as: UTF8.self))")
        XCTAssertEqual(report["success"] as? Bool, true, "Actual WK capability failure: \(report["error"] ?? "unknown")")
        XCTAssertEqual(report["crossOriginIsolated"] as? Bool, true)
        XCTAssertEqual(report["sharedArrayBuffer"] as? String, "function")
        XCTAssertEqual(report["worker"] as? String, "function")
        XCTAssertGreaterThan((report["heartbeats"] as? NSNumber)?.intValue ?? 0, 0)
        let capacity = try XCTUnwrap((report["capacity"] as? NSNumber)?.intValue)
        let total = try XCTUnwrap((report["total"] as? NSNumber)?.intValue)
        XCTAssertGreaterThan(total, capacity)
        for key in ["first", "fresh"] {
            let transfer = try XCTUnwrap(report[key] as? [String: Any])
            XCTAssertEqual((transfer["sent"] as? NSNumber)?.intValue, total)
            XCTAssertEqual((transfer["received"] as? NSNumber)?.intValue, total)
            XCTAssertEqual(transfer["eof"] as? Bool, true)
            XCTAssertLessThan((transfer["firstOutputSent"] as? NSNumber)?.intValue ?? total, total,
                              "Output must arrive before all input has been fed")
        }
        let cancel = try XCTUnwrap(report["cancel"] as? [String: Any])
        XCTAssertEqual(cancel["waiting"] as? Bool, true)
        XCTAssertEqual(cancel["cancelled"] as? Bool, true)
        XCTAssertEqual(cancel["lastWait"] as? String, "ok", "Cancel must wake actual Atomics.wait")
    }
    #endif
}

nonisolated private enum VirtualPythonPlatformAssets {
    static let worker = #"""
    'use strict';
    const R=0,W=1,EOF=2,CANCEL=3,SIGNAL=4,H=5;
    onmessage=e=>{
     const {input,output,capacity,mode}=e.data;
     const a=new Int32Array(input,0,H),b=new Int32Array(output,0,H);
     const ai=new Uint8Array(input,H*4),bo=new Uint8Array(output,H*4);
     let waits=0,count=0,reported=false,lastWait=null;
     try{
      if(!crossOriginIsolated||typeof SharedArrayBuffer!=='function')throw Error('worker isolation unavailable');
      const probe=new Int32Array(new SharedArrayBuffer(4));
      const probeResult=Atomics.wait(probe,0,0,1);
      if(probeResult!=='timed-out')throw Error('worker Atomics.wait unavailable');
      postMessage({ready:true,isolated:crossOriginIsolated,atomicsWait:probeResult});
      while(true){
       if(Atomics.load(a,CANCEL)||Atomics.load(b,CANCEL)){postMessage({cancelled:true,waits,count,lastWait});return;}
       const inputSignal=Atomics.load(a,SIGNAL);
       let read=Atomics.load(a,R),written=Atomics.load(a,W);
       if(read===written){
        if(Atomics.load(a,EOF)){Atomics.store(b,EOF,1);Atomics.add(b,SIGNAL,1);Atomics.notify(b,SIGNAL);postMessage({done:true,waits,count,eof:true});return;}
        if(mode==='cancel'&&!reported){reported=true;postMessage({waiting:true});}
        waits++;
        if(Atomics.load(a,CANCEL))continue;
        lastWait=Atomics.wait(a,SIGNAL,inputSignal,5000);
        continue;
       }
       const value=ai[read%capacity]^0xa5;
       // Publish consumed input before waiting for output capacity: duplex flow.
       Atomics.store(a,R,read+1);Atomics.add(a,SIGNAL,1);Atomics.notify(a,SIGNAL);
       while(true){
        const outputSignal=Atomics.load(b,SIGNAL);
        if(Atomics.load(b,W)-Atomics.load(b,R)<capacity)break;
        if(Atomics.load(a,CANCEL)||Atomics.load(b,CANCEL)){postMessage({cancelled:true,waits,count,lastWait});return;}
        waits++;Atomics.wait(b,SIGNAL,outputSignal,5000);
       }
       const out=Atomics.load(b,W);bo[out%capacity]=value;
       Atomics.store(b,W,out+1);Atomics.add(b,SIGNAL,1);Atomics.notify(b,SIGNAL);count++;
      }
     }catch(error){postMessage({failure:String(error)});}
    };
    """#
    static let main = #"""
    'use strict';
    const R=0,W=1,EOF=2,CANCEL=3,SIGNAL=4,H=5,capacity=256,total=65537;
    const active=new Set();let cancelled=false;let heartbeats=0;
    const heartbeat=setInterval(()=>heartbeats++,5);
    function buffers(){return [new SharedArrayBuffer(H*4+capacity),new SharedArrayBuffer(H*4+capacity)];}
    function stopPair(a,b){Atomics.store(a,CANCEL,1);Atomics.store(b,CANCEL,1);for(const x of[a,b]){Atomics.add(x,SIGNAL,1);Atomics.notify(x,SIGNAL);}}
    globalThis.platformTeardown=()=>{cancelled=true;clearInterval(heartbeat);for(const stop of active)stop();active.clear();};
    function stream(){return new Promise((resolve,reject)=>{
     const [input,output]=buffers(),a=new Int32Array(input,0,H),b=new Int32Array(output,0,H),ai=new Uint8Array(input,H*4),bo=new Uint8Array(output,H*4);
     const worker=new Worker('worker.js');let sent=0,received=0,ready=false,done=false,workerWaits=0,firstOutputSent=null,pumps=0,started=performance.now(),timer=null,finished=false;
     const stop=()=>{stopPair(a,b);worker.terminate();clearTimeout(timer);};active.add(stop);
     const finish=(error)=>{if(finished)return;finished=true;stop();active.delete(stop);if(error)reject(error);else resolve({sent,received,eof:Atomics.load(b,EOF)===1,workerWaits,pumps,firstOutputSent,durationMs:performance.now()-started});};
     const pump=()=>{
      if(cancelled){finish(Error('test cancelled'));return;}
      if(performance.now()-started>7000){finish(Error('stream deadline'));return;}
      pumps++;
      if(ready){
       // Always drain output and feed input in the same nonblocking UI task.
       let read=Atomics.load(b,R),written=Atomics.load(b,W);
       while(read<written){if(firstOutputSent===null)firstOutputSent=sent;if(bo[read%capacity]!==(((received*31+7)&255)^0xa5)){finish(Error('binary order/corruption at '+received));return;}read++;received++;}
       Atomics.store(b,R,read);Atomics.add(b,SIGNAL,1);Atomics.notify(b,SIGNAL);
       let consumed=Atomics.load(a,R),writtenIn=Atomics.load(a,W);
       const end=Math.min(total,writtenIn+capacity-(writtenIn-consumed));
       while(writtenIn<end){ai[writtenIn%capacity]=(sent*31+7)&255;writtenIn++;sent++;}
       Atomics.store(a,W,writtenIn);Atomics.add(a,SIGNAL,1);Atomics.notify(a,SIGNAL);
       if(sent===total){Atomics.store(a,EOF,1);Atomics.add(a,SIGNAL,1);Atomics.notify(a,SIGNAL);}
       if(done&&received===total){finish(null);return;}
      }
      timer=setTimeout(pump,0);
     };
     worker.onerror=e=>finish(Error(e.message||'worker error'));
     worker.onmessage=e=>{const m=e.data;if(m.failure){finish(Error(m.failure));return;}if(m.ready){if(!m.isolated||m.atomicsWait!=='timed-out'){finish(Error('worker capability false'));return;}ready=true;}if(m.done){done=true;workerWaits=m.waits;if(m.count!==total||!m.eof)finish(Error('worker count/EOF mismatch'));}};
     worker.postMessage({input,output,capacity,mode:'stream'});pump();
    });}
    function cancelWaiting(){return new Promise((resolve,reject)=>{
     const [input,output]=buffers(),a=new Int32Array(input,0,H),b=new Int32Array(output,0,H),worker=new Worker('worker.js');let waiting=false,finished=false;
     const timer=setTimeout(()=>finish(Error('cancellation deadline')),3000);
     const stop=()=>{stopPair(a,b);worker.terminate();clearTimeout(timer);};active.add(stop);
     function finish(error,result){if(finished)return;finished=true;stop();active.delete(stop);error?reject(error):resolve(result);}
     worker.onerror=e=>finish(Error(e.message||'cancel worker error'));
     worker.onmessage=e=>{const m=e.data;if(m.failure){finish(Error(m.failure));return;}if(m.waiting){waiting=true;setTimeout(()=>{if(!finished)stopPair(a,b);},50);}if(m.cancelled){if(!waiting||m.waits<1||m.count!==0||m.lastWait!=='ok'){finish(Error('did not cancel blocked worker'));return;}finish(null,{waiting,cancelled:m.cancelled,waits:m.waits,count:m.count,lastWait:m.lastWait});}};
     worker.postMessage({input,output,capacity,mode:'cancel'});
    });}
    (async()=>{
     const result={crossOriginIsolated:globalThis.crossOriginIsolated===true,sharedArrayBuffer:typeof SharedArrayBuffer,worker:typeof Worker,capacity,total};
     try{
      if(!crossOriginIsolated||typeof SharedArrayBuffer!=='function'||typeof Worker!=='function')throw Error('Apple platform capability unavailable');
      result.first=await stream();result.cancel=await cancelWaiting();result.fresh=await stream();result.heartbeats=heartbeats;
      if(result.first.firstOutputSent>=total||result.fresh.firstOutputSent>=total||!result.first.eof||!result.fresh.eof||heartbeats===0)throw Error('not simultaneous duplex/EOF/UI progress');
      result.success=true;
     }catch(error){result.success=false;result.error=String(error);}
     platformTeardown();result.nonce=globalThis.platformNonce;
     document.getElementById('result').textContent=JSON.stringify(result);
     if(globalThis.webkit?.messageHandlers?.platformResult)globalThis.webkit.messageHandlers.platformResult.postMessage(result);
     document.documentElement.dataset.done='true';
    })();
    """#
}

import Foundation

@main
struct ConfigGenerationSmoke {
    static func main() async throws {
        let openAIHelpCenterDomains = [
            "auth.openai.com",
            "chatgpt.com",
            "ct.sendgrid.net",
            "intercom.io",
            "intercomcdn.com",
            "oaistatic.com",
            "oaiusercontent.com",
            "openai.com",
            "api.oaistatsig.com",
            "android.chat.openai.com",
            "auth0.openai.com",
            "cdn.openaimerge.com",
            "cdn.workos.com",
            "challenges.cloudflare.com",
            "chat.openai.com",
            "desktop.chat.openai.com",
            "forwarder.workos.com",
            "humb.apple.com",
            "images.workoscdn.com",
            "ios.chat.openai.com",
            "js.intercomcdn.com",
            "js.stripe.com",
            "o207216.ingest.sentry.io",
            "o33249.ingest.sentry.io",
            "rum.browser-intake-datadoghq.com",
            "setup.auth.openai.com",
            "setup.workos.com",
            "tcr9i.chat.openai.com",
            "workos.imgix.net"
        ]
        for domain in openAIHelpCenterDomains {
            precondition(
                DefaultRules.routeDecision(
                    for: domain,
                    vpnDomains: VpnDomainList.defaults.domains,
                    unknownTrafficPolicy: "direct"
                ).outbound == "proxy",
                "OpenAI Help Center domain must route explicitly through the proxy: \(domain)"
            )
        }

        let domainMigrationRoot = URL(
            fileURLWithPath: "/private/tmp/split-vpn-domain-migration-smoke-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: domainMigrationRoot) }
        let domainMigrationStore = AppGroupStore(rootURL: domainMigrationRoot)
        let legacyDomainData = try JSONEncoder().encode(
            VpnDomainList(domains: ["custom.example"], defaultsVersion: 4)
        )
        try legacyDomainData.write(to: domainMigrationStore.url("vpn-domains.json"))
        let migratedDomains = domainMigrationStore.readDomains()
        precondition(domainMigrationStore.isTunnelRequested(), "Legacy installs preserve system start behavior")
        try domainMigrationStore.setTunnelRequested(false)
        precondition(!AppGroupStore(rootURL: domainMigrationRoot).isTunnelRequested(), "Manual stop survives a new process/store")
        try domainMigrationStore.setTunnelRequested(true)
        precondition(AppGroupStore(rootURL: domainMigrationRoot).isTunnelRequested(), "Explicit connect clears manual stop")
        precondition(migratedDomains.defaultsVersion == 5, "VPN domain defaults should migrate to version 5")
        precondition(migratedDomains.domains.contains("custom.example"), "VPN domain migration must preserve custom domains")
        precondition(migratedDomains.domains.contains("oaistatsig.com"), "VPN domain migration must add oaistatsig.com")

        precondition(
            LibboxDiagnosticsPolicy.standardStatusIntervalNanoseconds == 30_000_000_000,
            "Standard diagnostics must use an explicit 30-second nanosecond interval"
        )
        var sampledRecovery = TunnelRecoveryPolicy()
        sampledRecovery.start(now: 0)
        let sampleInterval = Double(LibboxDiagnosticsPolicy.statusIntervalNanoseconds(for: .standard)) / 1_000_000_000
        precondition(sampleInterval * 3 <= sampledRecovery.heartbeatTimeout,
                     "Standard sampling must leave room for delayed heartbeats")
        for sampleAt in stride(from: sampleInterval, through: 300, by: sampleInterval) {
            // One missed update plus modest scheduling delay must not restart an idle tunnel.
            precondition(!sampledRecovery.heartbeatExpired(now: sampleAt + sampleInterval + 5),
                         "A delayed zero-traffic status update must not cause a false failure")
            sampledRecovery.heartbeat(now: sampleAt)
        }
        precondition(!sampledRecovery.heartbeatExpired(now: 389) && sampledRecovery.heartbeatExpired(now: 390),
                     "Loss of the status stream must still be detected after 90 seconds")
        precondition(
            LibboxDiagnosticsPolicy.deepStatusIntervalNanoseconds >= LibboxDiagnosticsPolicy.minimumIntervalNanoseconds,
            "Deep diagnostics must never poll faster than the one-second safety floor"
        )
        precondition(
            !LibboxDiagnosticsPolicy.includesConnectionEvents(for: .standard) &&
                LibboxDiagnosticsPolicy.includesConnectionEvents(for: .deep),
            "Connection events should only run during deep diagnostics"
        )

        let checkpointStartedAt = Date(timeIntervalSince1970: 100)
        let checkpointBaseline = RuntimeStatus(
            state: .connected,
            startedAt: checkpointStartedAt,
            lastError: "",
            bytesIn: 1_000,
            bytesOut: 1_000
        )
        let checkpointTraffic = RuntimeStatus(
            state: .connected,
            startedAt: checkpointStartedAt,
            lastError: "",
            bytesIn: 400_000,
            bytesOut: 1_000
        )
        precondition(
            !RuntimeStatusCheckpointPolicy.shouldCheckpoint(
                previous: checkpointBaseline,
                next: checkpointTraffic,
                lastCheckpointAt: checkpointStartedAt,
                now: checkpointStartedAt.addingTimeInterval(59)
            ),
            "Traffic checkpoints should not write more than once per minute"
        )
        precondition(
            RuntimeStatusCheckpointPolicy.shouldCheckpoint(
                previous: checkpointBaseline,
                next: checkpointTraffic,
                lastCheckpointAt: checkpointStartedAt,
                now: checkpointStartedAt.addingTimeInterval(60)
            ),
            "Traffic checkpoints should persist meaningful deltas after one minute"
        )
        precondition(
            RuntimeStatusCheckpointPolicy.shouldCheckpoint(
                previous: checkpointBaseline,
                next: checkpointBaseline,
                lastCheckpointAt: checkpointStartedAt,
                now: checkpointStartedAt.addingTimeInterval(300)
            ),
            "Idle runtime state should receive a five-minute durability checkpoint"
        )

        let healthStart = Date(timeIntervalSince1970: 1_000)
        var healthMonitor = DataPlaneHealthMonitor()
        let ignoredHealthMessages = [
            "outbound/direct[direct]: receive ICMP echo reply: i/o timeout",
            "router: UDP is not supported by outbound: proxy",
            "connection: report handshake success: connection refused"
        ]
        for (index, message) in ignoredHealthMessages.enumerated() {
            precondition(
                healthMonitor.observe(logMessage: message, at: healthStart.addingTimeInterval(Double(index))) == nil,
                "Non-TCP-dial warnings must not trigger data-plane recovery"
            )
        }
        let directTimeout: (Int) -> String = { index in
            "connection: open connection to direct-\(index).example.test:443 using outbound/direct[direct]: dial tcp 10.0.0.8:443: i/o timeout"
        }
        let proxyTimeout: (Int) -> String = { index in
            "connection: open connection to proxy-\(index).example.test:443 using outbound/http[Sample]: dial tcp 10.0.0.8:443: i/o timeout"
        }
        for index in 1...DataPlaneHealthMonitor.mixedDirectThreshold {
            precondition(
                healthMonitor.observe(logMessage: directTimeout(index), at: healthStart.addingTimeInterval(Double(index))) == nil,
                "Direct timeouts below the direct-only threshold must not recover prematurely"
            )
        }
        precondition(
            healthMonitor.observe(logMessage: proxyTimeout(1), at: healthStart.addingTimeInterval(7)) == nil,
            "A single proxy timeout must not trigger recovery"
        )
        let mixedIncident = healthMonitor.observe(
            logMessage: proxyTimeout(2),
            at: healthStart.addingTimeInterval(8)
        )
        precondition(
            mixedIncident?.reason == "mixed_direct_proxy_tcp_timeout_burst" &&
                mixedIncident?.directTimeoutCount == DataPlaneHealthMonitor.mixedDirectThreshold &&
                mixedIncident?.proxyTimeoutCount == DataPlaneHealthMonitor.mixedProxyThreshold,
            "A multi-endpoint direct/proxy timeout burst should trigger one recovery incident"
        )
        for index in 20..<(20 + DataPlaneHealthMonitor.directOnlyThreshold) {
            let cooldownIncident = healthMonitor.observe(
                logMessage: directTimeout(index),
                at: healthStart.addingTimeInterval(20 + Double(index - 20) / 2)
            )
            precondition(cooldownIncident == nil, "Recovery incidents must respect the two-minute cooldown")
        }
        var directOnlyMonitor = DataPlaneHealthMonitor()
        var directOnlyIncident: DataPlaneHealthIncident?
        for index in 40..<(40 + DataPlaneHealthMonitor.directOnlyThreshold) {
            directOnlyIncident = directOnlyMonitor.observe(
                logMessage: directTimeout(index),
                at: healthStart.addingTimeInterval(Double(index - 40) / 2)
            ) ?? directOnlyIncident
        }
        precondition(
            directOnlyIncident?.reason == "direct_tcp_timeout_burst" &&
                directOnlyIncident?.uniqueEndpointCount == DataPlaneHealthMonitor.directOnlyThreshold,
            "A broad direct-only TCP timeout burst should recover even without proxy background traffic"
        )
        var singleEndpointMonitor = DataPlaneHealthMonitor()
        var singleEndpointIncident: DataPlaneHealthIncident?
        for index in 0..<DataPlaneHealthMonitor.directOnlyThreshold {
            singleEndpointIncident = singleEndpointMonitor.observe(
                logMessage: directTimeout(99),
                at: healthStart.addingTimeInterval(Double(index) / 2)
            ) ?? singleEndpointIncident
        }
        precondition(
            singleEndpointIncident == nil,
            "Repeated failures to one endpoint must not be mistaken for a system-wide data-plane outage"
        )

        for failure in ["i/o timeout", "connection refused", "connection reset", "network is unreachable"] {
            var monitor = DataPlaneHealthMonitor()
            var incident: DataPlaneHealthIncident?
            for index in 0..<DataPlaneHealthMonitor.proxyOnlyThreshold {
                incident = monitor.observe(
                    logMessage: proxyTimeout(index).replacingOccurrences(of: "i/o timeout", with: failure),
                    at: healthStart.addingTimeInterval(Double(index))
                ) ?? incident
            }
            precondition(incident?.reason == "proxy_connection_failure_burst", "Proxy-only failures must recover: \(failure)")
        }

        let vmessPayload = """
        {"v":"2","ps":"vmess sample","add":"vmess.example.com","port":"443","id":"00000000-0000-0000-0000-000000000001","aid":"0","scy":"auto","net":"tcp","tls":"tls","sni":"vmess.example.com"}
        """.data(using: .utf8)!.base64EncodedString()

        let subscription = """
        ss://YWVzLTEyOC1nY206cGFzc3dvcmRAc3MuZXhhbXBsZS5jb206ODM4OA==?udp=true#ss%20sample
        hysteria2://hy2pass@hy2.example.com:443?obfs=salamander&obfs-password=obfspass&sni=hy2.example.com#hy2%20sample
        trojan://password@trojan.example.com:443?security=tls&sni=trojan.example.com#trojan%20sample
        tuic://00000000-0000-0000-0000-000000000003:tuicpass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&sni=tuic.example.com#tuic%20sample
        vless://00000000-0000-0000-0000-000000000002@vless.example.com:443?security=tls&type=ws&path=%2Fws&host=vless.example.com#vless%20sample
        vless://00000000-0000-0000-0000-000000000004@reality.example.com:443?security=reality&type=grpc&serviceName=grpc-svc&sni=www.example.com&fp=chrome&pbk=MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE&sid=abcd&flow=xtls-rprx-vision&alpn=h2%2Chttp%2F1.1#vless%20reality%20grpc
        vmess://\(vmessPayload)
        """

        let core = CoreClient(
            rootURL: URL(fileURLWithPath: "/private/tmp/split-vpn-core-smoke-\(UUID().uuidString)", isDirectory: true)
        )
        let subscriptionID = try await core.saveSubscription(url: "https://sub.example.com/smoke")
        let plan = try await core.object("subscription:plan", ["id": subscriptionID])
        let accepted = try await core.object(
            "subscription:accept",
            ["id": subscriptionID, "token": plan["token"] ?? "", "index": 0, "status": 200, "content": subscription]
        )
        precondition(accepted["done"] as? Bool == true && accepted["ok"] as? Bool == true, "Core should accept the URI subscription: \(accepted)")
        let subscriptionRecord = CoreClient.subscriptionRecord(from: try await core.subscriptionStatus())
        precondition(subscriptionRecord.url == "https://sub.example.com/smoke", "Core subscription mirror should keep the URL")
        precondition(subscriptionRecord.nodeCount == 7, "Expected 7 core nodes, got \(subscriptionRecord.nodeCount)")
        precondition(subscriptionRecord.updatedAt != nil, "Core subscription mirror should parse updatedAt")
        let allNodes = try await core.nodes()
        precondition(allNodes.count == 7, "Expected 7 listed nodes, got \(allNodes.count)")
        precondition(allNodes.first(where: { $0.name == "vless sample" })?.server == "vless.example.com", "Core node list should expose the server")
        precondition(allNodes.first(where: { $0.name == "vless sample" })?.port == 443, "Core node list should expose the port")

        let vpnDomains = ["openai.com", "youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "gvt1.com"]
        let geoRoutingResources = GeoRoutingResources(
            geoipCNPath: "/private/tmp/geoip-cn.srs",
            geositeCNPath: "/private/tmp/geosite-cn.srs",
            geositeNonCNPath: "/private/tmp/geosite-geolocation-!cn.srs"
        )
        func generate(_ settings: AppSettings) async throws -> (GeneratedTunnelConfig, [String: Any]) {
            let generated = try await core.generateTunnelConfig(
                settings: settings,
                domains: VpnDomainList(domains: vpnDomains),
                geoRoutingResources: geoRoutingResources
            )
            guard let data = generated.singBoxJSON?.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                fatalError("Generated sing-box JSON is invalid")
            }
            return (generated, json)
        }

        let (generated, json) = try await generate(
            AppSettings(selectedProxy: "vless sample", unknownTrafficPolicy: AppSettings.defaults.unknownTrafficPolicy)
        )
        guard let jsonText = generated.singBoxJSON,
              let outbounds = json["outbounds"] as? [[String: Any]],
              let route = json["route"] as? [String: Any],
              let routeRules = route["rules"] as? [[String: Any]] else {
            fatalError("Generated sing-box JSON is missing outbounds or route")
        }
        if let outputPath = ProcessInfo.processInfo.environment["SPLITVPN_SMOKE_WRITE_CONFIG"],
           !outputPath.isEmpty {
            try jsonText.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }

        guard let inbounds = json["inbounds"] as? [[String: Any]],
              let tunInbound = inbounds.first(where: { $0["type"] as? String == "tun" }) else {
            fatalError("Generated sing-box JSON is missing tun inbound")
        }
        precondition(tunInbound["mtu"] as? Int == 1400, "sing-box tun inbound should use the default Packet Tunnel MTU")
        precondition(generated.packetTunnelMTU == 1400, "GeneratedTunnelConfig metadata should record the default Packet Tunnel MTU")
        precondition(TunnelAddressing.mtu == 1400, "Packet Tunnel MTU should be lowered for iOS encapsulation stability")
        precondition(generated.providerNodeCount == 7, "GeneratedTunnelConfig should count provider nodes")
        precondition(generated.convertedOutboundCount == 7, "Expected 7 converted outbounds, got \(generated.convertedOutboundCount ?? -1)")
        precondition(generated.unsupportedNodeCount == 0, "Expected 0 unsupported nodes")
        precondition(generated.selectedProxy == "vless sample", "GeneratedTunnelConfig metadata should keep selected proxy name")
        precondition(generated.selectedOutboundTag == "vless-sample", "GeneratedTunnelConfig metadata should record selected outbound tag")
        precondition(generated.selectedProxyStatus == "manual-converted", "GeneratedTunnelConfig metadata should mark manual converted selection")
        precondition(
            outbounds.first(where: { $0["tag"] as? String == "proxy" })?["default"] as? String == "vless-sample",
            "proxy selector should default to the selected node"
        )
        precondition(route["default_domain_resolver"] as? String == "cloudflare-direct", "Default proxy server resolver should be cloudflare-direct")
        precondition(
            Set((route["rule_set"] as? [[String: Any]] ?? []).compactMap { $0["tag"] as? String })
                == ["geosite-cn", "geoip-cn", "geosite-geolocation-!cn"],
            "Bundled geo rule sets should be referenced"
        )
        precondition(
            routeRules.contains { ($0["domain_suffix"] as? [String])?.contains("openai.com") == true && $0["outbound"] as? String == "proxy" },
            "iPhone VPN domains should route through proxy"
        )

        let (mtu1280Generated, mtu1280JSON) = try await generate(
            AppSettings(selectedProxy: "vless sample", unknownTrafficPolicy: "direct", packetTunnelMTU: 1280)
        )
        precondition(mtu1280Generated.packetTunnelMTU == 1280, "GeneratedTunnelConfig metadata should record custom Packet Tunnel MTU")
        precondition(
            (mtu1280JSON["inbounds"] as? [[String: Any]])?.first?["mtu"] as? Int == 1280,
            "sing-box tun inbound should use custom Packet Tunnel MTU"
        )

        let (_, aliJSON) = try await generate(
            AppSettings(selectedProxy: "vless sample", unknownTrafficPolicy: "direct", proxyServerDomainResolver: ProxyServerDomainResolver.ali)
        )
        precondition((aliJSON["route"] as? [String: Any])?["default_domain_resolver"] as? String == "ali", "Ali resolver should be selectable")

        let (missingGenerated, _) = try await generate(
            AppSettings(selectedProxy: "missing sample", unknownTrafficPolicy: "direct")
        )
        precondition(missingGenerated.selectedOutboundTag == "block", "Missing manual selected nodes should resolve to block")
        precondition(missingGenerated.selectedProxyStatus == "manual-missing", "Missing manual selected nodes should not be marked converted")

        // Leave the core on the vless selection the diagnostic checks below expect.
        _ = try await generate(AppSettings(selectedProxy: "vless sample", unknownTrafficPolicy: AppSettings.defaults.unknownTrafficPolicy))

        let probeStartedAt = Date(timeIntervalSince1970: 1_000)
        let probeRecords = [
            ConnectivityProbeRecord(
                targetID: "google",
                targetName: "Google",
                urlString: "https://www.google.com/generate_204",
                startedAt: probeStartedAt,
                roundIndex: 1,
                roundCount: 3,
                durationMilliseconds: 100,
                firstByteMilliseconds: 80,
                dnsMilliseconds: 10,
                connectMilliseconds: 20,
                tlsMilliseconds: 30,
                serverWaitMilliseconds: 50,
                statusCode: 204,
                responseBytes: 0,
                bodyPreview: nil,
                errorMessage: nil
            ),
            ConnectivityProbeRecord(
                targetID: "google",
                targetName: "Google",
                urlString: "https://www.google.com/generate_204",
                startedAt: probeStartedAt.addingTimeInterval(1),
                roundIndex: 2,
                roundCount: 3,
                durationMilliseconds: 4_000,
                firstByteMilliseconds: 120,
                dnsMilliseconds: 20,
                connectMilliseconds: 30,
                tlsMilliseconds: 40,
                serverWaitMilliseconds: 60,
                statusCode: nil,
                responseBytes: 0,
                bodyPreview: nil,
                errorMessage: "timed out"
            ),
            ConnectivityProbeRecord(
                targetID: "google",
                targetName: "Google",
                urlString: "https://www.google.com/generate_204",
                startedAt: probeStartedAt.addingTimeInterval(2),
                roundIndex: 3,
                roundCount: 3,
                durationMilliseconds: 200,
                firstByteMilliseconds: 180,
                dnsMilliseconds: 30,
                connectMilliseconds: 40,
                tlsMilliseconds: 50,
                serverWaitMilliseconds: 70,
                statusCode: 204,
                responseBytes: 0,
                bodyPreview: nil,
                errorMessage: nil
            )
        ]
        let probeStats = ConnectivityProbeStatsCalculator.summarize(probeRecords)
        guard let googleProbeStats = probeStats.first(where: { $0.targetID == "google" }) else {
            fatalError("Connectivity probe stats should include Google")
        }
        precondition(googleProbeStats.count == 3, "Connectivity probe stats should count all rounds")
        precondition(googleProbeStats.roundCount == 3, "Connectivity probe stats should keep configured round count")
        precondition(googleProbeStats.successCount == 2, "Connectivity probe stats should count successful responses")
        precondition(googleProbeStats.p50Milliseconds == 200, "Connectivity probe stats should calculate p50 from sorted durations")
        precondition(googleProbeStats.p50FirstByteMilliseconds == 120, "Connectivity probe stats should calculate p50 first-byte timing")
        precondition(googleProbeStats.p50DNSMilliseconds == 20, "Connectivity probe stats should calculate p50 DNS timing")
        precondition(googleProbeStats.p50ConnectMilliseconds == 30, "Connectivity probe stats should calculate p50 connect timing")
        precondition(googleProbeStats.p50TLSMilliseconds == 40, "Connectivity probe stats should calculate p50 TLS timing")
        precondition(googleProbeStats.p50ServerWaitMilliseconds == 60, "Connectivity probe stats should calculate p50 server wait timing")
        precondition(googleProbeStats.summaryText.contains("ttfb_p50_ms=120"), "Connectivity probe stats summary should include first-byte timing")
        precondition(googleProbeStats.summaryText.contains("server_wait_p50_ms=60"), "Connectivity probe stats summary should include server wait timing")
        precondition(googleProbeStats.maxMilliseconds == 4_000, "Connectivity probe stats should record max duration")
        precondition(googleProbeStats.slow3sCount == 1, "Connectivity probe stats should count requests at or above 3 seconds")
        precondition(googleProbeStats.latestErrorMessage == "timed out", "Connectivity probe stats should keep the latest error")

        let diagnosticStore = AppGroupStore(
            rootURL: URL(fileURLWithPath: "/private/tmp/split-vpn-diagnostic-smoke-\(UUID().uuidString)", isDirectory: true)
        )
        let diagnosticNow = Date()
        let deepDiagnostics = DiagnosticsSettings.deep(now: diagnosticNow)
        try diagnosticStore.saveDiagnosticsSettings(deepDiagnostics, now: diagnosticNow)
        precondition(
            diagnosticStore.readDiagnosticsSettings(now: diagnosticNow).mode == .deep,
            "Deep diagnostics settings should round-trip through the App Group store"
        )
        try diagnosticStore.saveSettings(
            AppSettings(
                selectedProxy: "vless sample",
                unknownTrafficPolicy: AppSettings.defaults.unknownTrafficPolicy
            )
        )
        try diagnosticStore.saveDomains(VpnDomainList(domains: vpnDomains))
        try diagnosticStore.saveNodes(allNodes)
        try diagnosticStore.saveGeneratedConfig(generated)
        try diagnosticStore.saveConnectivityProbeResults(probeRecords)
        diagnosticStore.appendLog(level: "info", message: "Libbox connection new domain=www.google.com outbound=vless-sample rule=domain")
        diagnosticStore.appendLog(level: "info", message: "Network path baseline status=satisfied interface=wifi")
        diagnosticStore.appendLog(level: "info", message: "Libbox openTun using fd 10")
        precondition(
            !FileManager.default.fileExists(atPath: diagnosticStore.url("logs/latest.json").path),
            "Info diagnostics should remain buffered until a batch or flush boundary"
        )
        precondition(diagnosticStore.readLogs().count == 3, "Buffered logs should remain visible to the current process")
        let diagnosticReport = diagnosticStore.makeDiagnosticReport()
        precondition(
            FileManager.default.fileExists(atPath: diagnosticStore.url("logs/latest.json").path),
            "Diagnostic report generation should flush buffered logs"
        )
        precondition(diagnosticReport.contains("[diagnostic_summary]"), "Diagnostic report should include a summary section")
        precondition(diagnosticReport.contains("manual_selection=true"), "Diagnostic summary should identify manual selection")
        precondition(diagnosticReport.contains("status=manual-converted"), "Diagnostic summary should include selected proxy status")
        precondition(diagnosticReport.contains("selected_outbound_tag=vless-sample"), "Diagnostic summary should include selected outbound tag")
        precondition(diagnosticReport.contains("resolver_ok=true"), "Diagnostic summary should include resolver status")
        precondition(diagnosticReport.contains("connectivity_probe=slowest_target=Google"), "Diagnostic summary should include slowest probe target")
        precondition(diagnosticReport.contains("ttfb_p50_ms=120"), "Diagnostic summary should include first-byte timing")
        precondition(diagnosticReport.contains("server_wait_p50_ms=60"), "Diagnostic summary should include server wait timing")
        precondition(diagnosticReport.contains("event_counts connection=1 path=1 interface=1"), "Diagnostic summary should count key runtime events")
        precondition(diagnosticReport.contains("[diagnostics_mode]"), "Diagnostic report should include diagnostics mode")
        precondition(diagnosticReport.contains("mode: deep"), "Diagnostic report should identify deep diagnostics")
        precondition(diagnosticReport.contains("status_interval_ns: 5000000000"), "Deep diagnostics should report a five-second interval")
        precondition(
            diagnosticReport.contains("next_action=check_path_events_and_selected_node_stability"),
            "Diagnostic summary should include a next action"
        )
        try diagnosticStore.clearDiagnosticData()
        let cleanedDiagnosticReport = diagnosticStore.makeDiagnosticReport()
        precondition(
            cleanedDiagnosticReport.contains("connectivity_probe=missing run_more_connectivity_probe=true"),
            "Cleared diagnostic report should remove connectivity probe history"
        )
        precondition(
            cleanedDiagnosticReport.contains("event_counts connection=0 path=0 interface=0"),
            "Cleared diagnostic report should remove persisted runtime log counters"
        )
        precondition(
            cleanedDiagnosticReport.contains("result_count: 0"),
            "Cleared diagnostic report should show no connectivity probe results"
        )
        precondition(
            !cleanedDiagnosticReport.contains("Libbox connection new domain=www.google.com"),
            "Cleared diagnostic report should remove old log messages"
        )

        print("ConfigGenerationSmoke OK: nodes=\(allNodes.count), outbounds=\(outbounds.count)")
    }
}

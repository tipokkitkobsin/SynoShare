import Foundation

/// Where the share's sharing web API is reachable.
public struct ShareEndpoint: Sendable, Equatable {
    public let baseURL: URL
    public let relayRegion: String
    public let controlHost: String

    public init(baseURL: URL, relayRegion: String, controlHost: String) {
        self.baseURL = baseURL
        self.relayRegion = relayRegion
        self.controlHost = controlHost
    }
}

/// Resolves a gofile.me / QuickConnect link through Synology's coordinator.
///
/// Verified 2026-10-30 (docs/RESEARCH.md): the gofile web client derives the
/// relay host as `gofile-<hex(serverID)>.<relay_region>.quickconnect.<tld>`.
public enum QuickConnect {
    static let coordinators = ["global.quickconnect.to", "global.quickconnect.cn"]
    static let serviceID = "file_sharing_https"

    public static func relayHost(serverID: String, region: String, topDomain: String = "to") -> String {
        let hex = serverID.utf8.map { String(format: "%02x", $0) }.joined()
        return "gofile-\(hex).\(region).quickconnect.\(topDomain)"
    }

    public static func resolve(_ link: ShareLink, session: URLSession) async throws -> ShareEndpoint {
        var lastError = "no coordinator answered"
        for coordinator in coordinators {
            do {
                let info = try await serverCommand("get_server_info", link: link,
                                                   host: coordinator, session: session)
                guard let env = info["env"] as? [String: Any],
                      let region = env["relay_region"] as? String, !region.isEmpty,
                      let control = env["control_host"] as? String else {
                    lastError = "no relay region in reply"
                    continue
                }
                // The web client asks for a tunnel before using the relay; keep doing the same.
                _ = try? await serverCommand("request_tunnel", link: link, host: control, session: session)
                let tld = coordinator.hasSuffix(".cn") ? "cn" : "to"
                let host = relayHost(serverID: link.serverID, region: region, topDomain: tld)
                guard let base = URL(string: "https://\(host)") else { throw SynoError.invalidLink }
                return ShareEndpoint(baseURL: base, relayRegion: region, controlHost: control)
            } catch let error as SynoError {
                lastError = error.localizedDescription
            } catch {
                lastError = error.localizedDescription
            }
        }
        throw SynoError.serverNotFound(lastError)
    }

    private static func serverCommand(_ command: String, link: ShareLink, host: String,
                                      session: URLSession) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(host)/Serv.php") else { throw SynoError.invalidLink }
        let body: [[String: Any]] = [[
            "version": 1, "command": command, "stop_when_error": false,
            "stop_when_success": command == "request_tunnel", "id": serviceID,
            "serverID": link.serverID, "is_gofile": true, "path": link.serverID,
        ]]
        var request = URLRequest(url: url, timeoutInterval: command == "request_tunnel" ? 30 : 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SynoError.http(status: http.statusCode, context: command)
        }
        guard let replies = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = replies.first else { throw SynoError.unexpectedResponse(command) }
        let errno = first["errno"] as? Int ?? -1
        guard errno == 0 else { throw SynoError.serverNotFound("\(command) errno \(errno)") }
        return first
    }
}

import Foundation

struct ResolveLaunchIntent: Equatable {
    let sessionURL: URL?
    let serverURL: URL?

    static func from(arguments: [String]) -> ResolveLaunchIntent? {
        let sessionURL = parseFileURL(arguments: arguments, flag: "--resolve-session")
        let serverURL = parseWebURL(arguments: arguments, flag: "--resolve-server-url")

        guard sessionURL != nil || serverURL != nil else { return nil }
        return ResolveLaunchIntent(sessionURL: sessionURL, serverURL: serverURL)
    }

    func loadSessionPayload() throws -> ResolveSessionPayload {
        guard let sessionURL else {
            throw ResolveBridgeError.missingSessionURL
        }
        return try ResolveSessionPayload.load(from: sessionURL)
    }

    private static func parseFileURL(arguments: [String], flag: String) -> URL? {
        if let token = arguments.first(where: { $0.hasPrefix("\(flag)=") }) {
            return makeFileURL(fromPath: String(token.dropFirst(flag.count + 1)))
        }

        if let index = arguments.firstIndex(of: flag),
           arguments.indices.contains(index + 1) {
            return makeFileURL(fromPath: arguments[index + 1])
        }

        return nil
    }

    private static func parseWebURL(arguments: [String], flag: String) -> URL? {
        if let token = arguments.first(where: { $0.hasPrefix("\(flag)=") }) {
            return makeWebURL(fromString: String(token.dropFirst(flag.count + 1)))
        }

        if let index = arguments.firstIndex(of: flag),
           arguments.indices.contains(index + 1) {
            return makeWebURL(fromString: arguments[index + 1])
        }

        return nil
    }

    private static func makeFileURL(fromPath path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func makeWebURL(fromString rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}

struct ResolveSessionPayload: Codable, Equatable {
    var sessionID: String
    var mode: String
    var bridgePort: Int?
    var audioPath: String?
    var subtitleTrackIndex: Int?
    var templateName: String?
    var projectName: String?
    var timelineName: String?
    var timelineStart: TimeInterval?

    var audioURL: URL? {
        guard let audioPath, !audioPath.isEmpty else { return nil }
        return URL(fileURLWithPath: audioPath)
    }

    var serverURL: URL? {
        guard let bridgePort else { return nil }
        return ResolveBridgeClient.makeURL(port: bridgePort)
    }

    static func load(from url: URL) throws -> ResolveSessionPayload {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ResolveSessionPayload.self, from: data)
        } catch let error as DecodingError {
            throw ResolveBridgeError.invalidSessionPayload(url: url, underlyingError: error)
        } catch {
            throw ResolveBridgeError.invalidSessionFile(url: url, underlyingError: error)
        }
    }
}

struct ResolveBridgeTrackOption: Codable, Equatable {
    var value: String
    var label: String
}

struct ResolveBridgeTemplateOption: Codable, Equatable {
    var value: String
    var label: String
}

struct ResolveBridgeTimelineInfo: Codable, Equatable {
    var sessionID: String?
    var projectName: String?
    var name: String
    var timelineId: String?
    var timelineStart: TimeInterval
    var outputTracks: [ResolveBridgeTrackOption]
    var inputTracks: [ResolveBridgeTrackOption]
    var templates: [ResolveBridgeTemplateOption]
}

struct ResolveDaVinciExportRequest: Codable, Equatable {
    struct Segment: Codable, Equatable {
        var id: String
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    var command: String
    var sessionID: String
    var mode: String
    var templateName: String
    var trackIndex: Int
    var timelineStart: TimeInterval
    var projectName: String?
    var timelineName: String?
    var audioPath: String?
    var audioDuration: TimeInterval?
    var segments: [Segment]

    init(
        session: ResolveSessionPayload?,
        timelineInfo: ResolveBridgeTimelineInfo?,
        subtitles: [SubtitleItem],
        audioAsset: AudioAsset? = nil
    ) {
        command = "AddSubtitles"
        sessionID = session?.sessionID ?? timelineInfo?.sessionID ?? "resolve-bridge"
        mode = "addSubtitles"
        templateName = Self.normalizedTemplateName(session?.templateName, timelineInfo: timelineInfo)
        trackIndex = max(session?.subtitleTrackIndex ?? 1, 1)
        timelineStart = timelineInfo?.timelineStart ?? session?.timelineStart ?? 0
        projectName = timelineInfo?.projectName ?? session?.projectName
        timelineName = timelineInfo?.name ?? session?.timelineName
        audioPath = audioAsset?.url.path
        audioDuration = audioAsset?.duration
        segments = subtitles.map {
            Segment(id: $0.id.uuidString, start: $0.startTime, end: $0.endTime, text: $0.text)
        }
    }

    private static func normalizedTemplateName(_ value: String?, timelineInfo: ResolveBridgeTimelineInfo?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }

        if let defaultTemplate = timelineInfo?.templates.first(where: { $0.value == "Default Template" }) {
            return defaultTemplate.value
        }

        return "Default Template"
    }

    private enum CodingKeys: String, CodingKey {
        case command = "func"
        case sessionID
        case mode
        case templateName
        case trackIndex
        case timelineStart
        case projectName
        case timelineName
        case audioPath
        case audioDuration
        case segments
    }
}

private struct ResolveBridgeSimpleRequest: Encodable {
    var command: String

    init(command: String) {
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case command = "func"
    }
}

struct ResolveBridgeResponse: Decodable, Equatable {
    var message: String?
    var success: Bool?
    var error: String?
    var templateName: String?
    var trackIndex: Int?
    var added: Int?
    var audioAdded: Bool?
    var audioSkipped: Bool?
    var audioTrackIndex: Int?
}

struct ResolveBridgeClient {
    static let defaultPort = 56002
    static let host = "127.0.0.1"
    static let path = "/"
    static let timeout: TimeInterval = 10
    static let defaultServerURL = makeURL(port: defaultPort)

    let serverURL: URL
    let session: URLSession

    init(serverURL: URL = ResolveBridgeClient.defaultServerURL, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.session = session
    }

    static func makeURL(port: Int) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        return components.url ?? URL(string: "http://\(host):\(port)\(path)")!
    }

    func getTimelineInfo() async throws -> ResolveBridgeTimelineInfo {
        try await post(ResolveBridgeSimpleRequest(command: "GetTimelineInfo"), as: ResolveBridgeTimelineInfo.self)
    }

    func addSubtitles(_ request: ResolveDaVinciExportRequest) async throws -> ResolveBridgeResponse {
        try await post(request, as: ResolveBridgeResponse.self)
    }

    private func post<Body: Encodable, Response: Decodable>(_ requestBody: Body, as responseType: Response.Type) async throws -> Response {
        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        request.httpBody = try encoder.encode(requestBody)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ResolveBridgeError.bridgeRequestFailed(url: serverURL, underlyingError: URLError(.badServerResponse))
            }

            let responseBody = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ResolveBridgeError.bridgeRejected(url: serverURL, statusCode: httpResponse.statusCode, responseBody: responseBody)
            }

            if data.isEmpty {
                if let emptyResponse = ResolveBridgeResponse(message: nil, success: true, error: nil, templateName: nil, trackIndex: nil, added: nil) as? Response {
                    return emptyResponse
                }
                throw ResolveBridgeError.invalidBridgeResponse(url: serverURL, responseBody: responseBody)
            }

            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                if Response.self == ResolveBridgeResponse.self {
                    let fallback = ResolveBridgeResponse(
                        message: responseBody,
                        success: true,
                        error: nil,
                        templateName: nil,
                        trackIndex: nil,
                        added: nil
                    )
                    return fallback as! Response
                }
                throw ResolveBridgeError.invalidBridgeResponse(url: serverURL, responseBody: responseBody)
            }
        } catch let error as ResolveBridgeError {
            throw error
        } catch {
            throw ResolveBridgeError.bridgeRequestFailed(url: serverURL, underlyingError: error)
        }
    }
}

enum ResolveBridgeError: LocalizedError {
    case missingSessionURL
    case invalidSessionFile(url: URL, underlyingError: Error)
    case invalidSessionPayload(url: URL, underlyingError: Error)
    case bridgeRequestFailed(url: URL, underlyingError: Error)
    case bridgeRejected(url: URL, statusCode: Int, responseBody: String?)
    case invalidBridgeResponse(url: URL, responseBody: String?)

    var errorDescription: String? {
        switch self {
        case .missingSessionURL:
            return "Resolve session file path is missing."
        case let .invalidSessionFile(url, underlyingError):
            return "Resolve session file could not be read: \(url.path) (\(underlyingError.localizedDescription))"
        case let .invalidSessionPayload(url, underlyingError):
            return "Resolve session file is not valid JSON: \(url.path) (\(underlyingError.localizedDescription))"
        case let .bridgeRequestFailed(url, underlyingError):
            return "Resolve bridge request failed: \(url.absoluteString) (\(underlyingError.localizedDescription))"
        case let .bridgeRejected(url, statusCode, responseBody):
            let body = responseBody.flatMap { $0.isEmpty ? nil : $0 }
            if let body {
                return "Resolve bridge rejected the export: \(url.absoluteString) [\(statusCode)] (\(body))"
            }
            return "Resolve bridge rejected the export: \(url.absoluteString) [\(statusCode)]"
        case let .invalidBridgeResponse(url, responseBody):
            let body = responseBody.flatMap { $0.isEmpty ? nil : $0 } ?? "empty response"
            return "Resolve bridge returned an unexpected response: \(url.absoluteString) (\(body))"
        }
    }
}

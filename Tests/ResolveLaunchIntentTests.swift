@testable import SubtitleStudioPlus
import Foundation
import Testing

struct ResolveLaunchIntentTests {
    @Test
    func parsesSessionPathWithSeparatedArgument() {
        let intent = ResolveLaunchIntent.from(arguments: [
            "SubtitleStudioPlus",
            "--resolve-session",
            "/tmp/subtitle-studio/resolve_session.json",
        ])

        #expect(intent?.sessionURL?.path == "/tmp/subtitle-studio/resolve_session.json")
        #expect(intent?.serverURL == nil)
    }

    @Test
    func parsesSessionPathWithEqualsArgumentAndTildeExpansion() {
        let intent = ResolveLaunchIntent.from(arguments: [
            "--resolve-session=~/subtitle-studio/resolve_session.json"
        ])

        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("subtitle-studio/resolve_session.json")

        #expect(intent?.sessionURL == expected)
    }

    @Test
    func parsesServerURLArgument() {
        let intent = ResolveLaunchIntent.from(arguments: [
            "SubtitleStudioPlus",
            "--resolve-server-url",
            "http://127.0.0.1:56002/"
        ])

        #expect(intent?.sessionURL == nil)
        #expect(intent?.serverURL == URL(string: "http://127.0.0.1:56002/"))
    }

    @Test
    func loadsResolveSessionPayload() throws {
        let sessionURL = try makeSessionFile(
            """
            {
              "sessionID": "resolve-001",
              "mode": "launch",
              "bridgePort": 56002,
              "audioPath": "/tmp/audio.wav",
              "subtitleTrackIndex": 3,
              "templateName": "Default Template",
              "projectName": "Project Alpha",
              "timelineName": "Timeline One",
              "timelineStart": 12.5
            }
            """
        )

        let intent = ResolveLaunchIntent(sessionURL: sessionURL, serverURL: nil)
        let payload = try intent.loadSessionPayload()

        #expect(payload.sessionID == "resolve-001")
        #expect(payload.mode == "launch")
        #expect(payload.bridgePort == 56002)
        #expect(payload.audioURL?.path == "/tmp/audio.wav")
        #expect(payload.subtitleTrackIndex == 3)
        #expect(payload.templateName == "Default Template")
        #expect(payload.projectName == "Project Alpha")
        #expect(payload.timelineName == "Timeline One")
        #expect(payload.timelineStart == 12.5)
        #expect(payload.serverURL == URL(string: "http://127.0.0.1:56002/"))
    }

    @Test
    func buildsDaVinciExportRequestFromSessionAndTimeline() {
        let session = ResolveSessionPayload(
            sessionID: "resolve-004",
            mode: "launch",
            bridgePort: 56002,
            audioPath: nil,
            subtitleTrackIndex: 3,
            templateName: "Default Template",
            projectName: "Project Alpha",
            timelineName: "Timeline One",
            timelineStart: 12.5
        )
        let timelineInfo = ResolveBridgeTimelineInfo(
            sessionID: "resolve-004",
            projectName: "Project Alpha",
            name: "Timeline One",
            timelineId: "timeline-1",
            timelineStart: 12.5,
            outputTracks: [],
            inputTracks: [],
            templates: [.init(value: "Default Template", label: "Default Template")]
        )
        let subtitles = [
            SubtitleItem(startTime: 0.2, endTime: 1.8, text: "hello"),
            SubtitleItem(startTime: 2.1, endTime: 3.4, text: "line 1\nline 2"),
        ]

        let request = ResolveDaVinciExportRequest(session: session, timelineInfo: timelineInfo, subtitles: subtitles)

        #expect(request.command == "AddSubtitles")
        #expect(request.sessionID == "resolve-004")
        #expect(request.mode == "addSubtitles")
        #expect(request.templateName == "Default Template")
        #expect(request.trackIndex == 3)
        #expect(request.timelineStart == 12.5)
        #expect(request.projectName == "Project Alpha")
        #expect(request.timelineName == "Timeline One")
        #expect(request.segments.count == 2)
        #expect(request.segments[0].text == "hello")
        #expect(request.segments[1].text == "line 1\nline 2")
    }

    @Test
    func encodesDaVinciExportRequestWithFunctionKey() throws {
        let session = ResolveSessionPayload(
            sessionID: "resolve-005",
            mode: "launch",
            bridgePort: nil,
            audioPath: nil,
            subtitleTrackIndex: nil,
            templateName: nil,
            projectName: nil,
            timelineName: nil,
            timelineStart: nil
        )
        let timelineInfo = ResolveBridgeTimelineInfo(
            sessionID: "resolve-005",
            projectName: "Project Alpha",
            name: "Timeline One",
            timelineId: "timeline-1",
            timelineStart: 0,
            outputTracks: [],
            inputTracks: [],
            templates: [.init(value: "Default Template", label: "Default Template")]
        )

        let request = ResolveDaVinciExportRequest(session: session, timelineInfo: timelineInfo, subtitles: [])
        let encoded = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(object?["func"] as? String == "AddSubtitles")
        #expect(object?["templateName"] as? String == "Default Template")
        #expect((object?["segments"] as? [Any])?.isEmpty == true)
    }

    @Test
    @MainActor
    func resolveLaunchKeepsAudioManual() async throws {
        let sessionURL = try makeSessionFile(
            """
            {
              "sessionID": "resolve-006",
              "mode": "launch",
              "bridgePort": 56002,
              "projectName": "Project Alpha",
              "timelineName": "Timeline One"
            }
            """
        )

        let viewModel = AppViewModel()
        await viewModel.handleResolveLaunch(
            ResolveLaunchIntent(
                sessionURL: sessionURL,
                serverURL: URL(string: "http://127.0.0.1:56002/")
            )
        )

        #expect(viewModel.audioAsset == nil)
        #expect(viewModel.subtitles.isEmpty)
    }

    @Test
    @MainActor
    func standardExportKeepsFileExporter() {
        let viewModel = AppViewModel()
        viewModel.subtitles = [
            SubtitleItem(startTime: 0.2, endTime: 1.8, text: "hello")
        ]

        viewModel.requestStandardExport()

        #expect(viewModel.isFileExporterPresented)
        #expect(viewModel.canExportStandardSRT)
    }

    @Test
    func reportsInvalidSessionPayload() throws {
        let sessionURL = try makeSessionFile(
            """
            {
              "sessionID": "resolve-003",
              "mode":
            }
            """
        )

        let intent = ResolveLaunchIntent(sessionURL: sessionURL, serverURL: nil)

        #expect(throws: ResolveBridgeError.self) {
            try intent.loadSessionPayload()
        }
    }

    @Test
    func reportsMissingSessionFile() {
        let sessionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("resolve_session.json")

        let intent = ResolveLaunchIntent(sessionURL: sessionURL, serverURL: nil)

        #expect(throws: ResolveBridgeError.self) {
            try intent.loadSessionPayload()
        }
    }

    private func makeSessionFile(_ json: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)

        let sessionURL = tempURL.appendingPathComponent("resolve_session.json")
        try json.data(using: .utf8)!.write(to: sessionURL)
        return sessionURL
    }
}

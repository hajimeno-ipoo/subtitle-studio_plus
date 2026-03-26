@testable import SubtitleStudioPlus
import Foundation
import Testing

struct LocalPipelineJSONSchemaFixtureTests {
    @Test
    func chunksIndexFixtureDecodes() throws {
        let data = Data(
            """
            {
              "runId": "run-20260321-120000-ab12cd34",
              "sourceDuration": 215.42,
              "chunkLengthSeconds": 8.0,
              "overlapSeconds": 1.0,
              "chunks": [
                { "chunkId": "chunk-00001", "start": 0.0, "end": 8.0 }
              ]
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(LocalPipelineChunksIndex.self, from: data)
        #expect(decoded.runId == "run-20260321-120000-ab12cd34")
        #expect(decoded.chunks.count == 1)
    }

    @Test
    func baseChunkFixtureDecodes() throws {
        let data = Data(
            """
            {
              "chunkId": "chunk-00001",
              "engineType": "localPipeline",
              "baseModel": "kotobaWhisperV2",
              "language": "ja",
              "segments": [
                {
                  "segmentId": "chunk-00001-seg-0001",
                  "start": 0.35,
                  "end": 2.42,
                  "text": "あいしてる",
                  "confidence": 0.74
                }
              ]
            }
            """.utf8
        )
        let decoded = try JSONDecoder().decode(LocalPipelineBaseChunkOutput.self, from: data)
        #expect(decoded.engineType == "localPipeline")
        #expect(decoded.segments.first?.text == "あいしてる")
    }

    @Test
    func draftAndAlignmentFixturesDecode() throws {
        let draftData = Data(
            """
            {
              "runId": "run-20260321-120000-ab12cd34",
              "engineType": "localPipeline",
              "sourceFileName": "song01.wav",
              "baseModel": "kotobaWhisperV2",
              "segments": [
                {
                  "segmentId": "block-00001",
                  "chunkId": "chunk-00001",
                  "startTime": 10.42,
                  "endTime": 12.63,
                  "text": "愛してる",
                  "sourceSegmentIDs": ["chunk-00001-seg-0001"]
                }
              ]
            }
            """.utf8
        )
        let alignData = Data(
            """
            {
              "runId": "run-20260321-120000-ab12cd34",
              "engineType": "localPipeline",
              "modelName": "aeneas",
              "segments": [
                {
                  "segmentId": "block-00001",
                  "start": 10.42,
                  "end": 12.63,
                  "text": "愛してる"
                }
              ]
            }
            """.utf8
        )

        let draft = try JSONDecoder().decode(LocalPipelineDraftOutput.self, from: draftData)
        let aligned = try JSONDecoder().decode(LocalPipelineSegmentAlignmentOutput.self, from: alignData)

        #expect(draft.segments.first?.segmentId == "block-00001")
        #expect(aligned.modelName == "aeneas")
        #expect(aligned.segments.first?.text == "愛してる")
    }

    @Test
    func finalAndManifestFixturesDecode() throws {
        let finalData = Data(
            """
            {
              "runId": "run-20260321-120000-ab12cd34",
              "engineType": "localPipeline",
              "sourceFileName": "song01.wav",
              "baseModel": "kotobaWhisperV2",
              "alignmentModel": "aeneas",
              "segments": [
                {
                  "id": "A2B3C4D5-E6F7-48A1-9B2C-1234567890AB",
                  "segmentId": "block-00001",
                  "startTime": 10.42,
                  "endTime": 12.63,
                  "baseTranscript": "あいしてる",
                  "finalTranscript": "愛してる",
                  "corrections": [
                    {
                      "type": "dictionary",
                      "before": "あいしてる",
                      "after": "愛してる"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        let manifestData = Data(
            """
            {
              "runId": "run-20260321-120000-ab12cd34",
              "engineType": "localPipeline",
              "sourceFileName": "song01.wav",
              "sourceDuration": 215.42,
              "settingsSnapshot": {
                "baseModel": "kotobaWhisperV2",
                "language": "ja",
                "chunkLengthSeconds": 8.0,
                "overlapSeconds": 1.0
              },
              "stages": {
                "normalized": true,
                "chunked": true,
                "baseTranscribed": true,
                "aligned": false,
                "corrected": false,
                "outputsWritten": false
              }
            }
            """.utf8
        )

        let final = try JSONDecoder().decode(LocalPipelineFinalOutput.self, from: finalData)
        let manifest = try JSONDecoder().decode(RunDirectoryManifest.self, from: manifestData)

        #expect(final.segments.first?.finalTranscript == "愛してる")
        #expect(manifest.stages.outputsWritten == false)
    }

    @Test
    func runLogLineFixtureDecodes() throws {
        let lineData = Data(
            """
            {"timestamp":"2026-03-21T12:00:08+09:00","runId":"run-20260321-120000-ab12cd34","stage":"baseTranscribing","level":"INFO","message":"chunk completed","engineType":"localPipeline","chunkId":"chunk-00001"}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(RunLogLine.self, from: lineData)
        #expect(decoded.stage == "baseTranscribing")
        #expect(decoded.chunkId == "chunk-00001")
    }
}

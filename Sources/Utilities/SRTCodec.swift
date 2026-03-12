import Foundation

enum SRTCodec {
    static func formatSRTTime(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((seconds * 1000).rounded(.down))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let secs = (totalMilliseconds % 60_000) / 1_000
        let millis = totalMilliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    static func formatDisplayTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let fraction = Int((seconds.truncatingRemainder(dividingBy: 1) * 100).rounded(.down))
        return String(format: "%02d:%02d.%02d", minutes, secs, fraction)
    }

    static func parseTime(_ string: String) -> TimeInterval {
        let normalized = string.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let parts = normalized.split(separator: ":")
        switch parts.count {
        case 2:
            let minutes = Double(parts[0]) ?? 0
            let seconds = Double(parts[1]) ?? 0
            return minutes * 60 + seconds
        case 3...:
            let hours = Double(parts[0]) ?? 0
            let minutes = Double(parts[1]) ?? 0
            let seconds = Double(parts[2]) ?? 0
            return hours * 3600 + minutes * 60 + seconds
        default:
            return 0
        }
    }

    static func generateSRT(from subtitles: [SubtitleItem]) -> String {
        subtitles.enumerated().map { index, subtitle in
            """
            \(index + 1)
            \(formatSRTTime(subtitle.startTime)) --> \(formatSRTTime(subtitle.endTime))
            \(subtitle.text)
            """
        }
        .joined(separator: "\n\n")
    }

    static func parseSRT(_ content: String) -> [SubtitleItem] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let timeRegex = try! NSRegularExpression(pattern: #"((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)\s*-?->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?)"#)
        var items: [SubtitleItem] = []
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?
        var currentText: [String] = []

        func flush() {
            guard let start = currentStart, let end = currentEnd, !currentText.joined().isEmpty else {
                currentStart = nil
                currentEnd = nil
                currentText = []
                return
            }
            items.append(
                SubtitleItem(
                    startTime: start,
                    endTime: end,
                    text: currentText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            currentStart = nil
            currentEnd = nil
            currentText = []
        }

        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }

            let fullRange = NSRange(location: 0, length: line.utf16.count)
            if let match = timeRegex.firstMatch(in: line, range: fullRange),
               let startRange = Range(match.range(at: 1), in: line),
               let endRange = Range(match.range(at: 2), in: line) {
                flush()
                currentStart = parseTime(String(line[startRange]))
                currentEnd = parseTime(String(line[endRange]))
                continue
            }

            if Int(line) != nil, index + 1 < lines.count {
                let nextLine = lines[index + 1]
                let nextRange = NSRange(location: 0, length: nextLine.utf16.count)
                if timeRegex.firstMatch(in: nextLine, range: nextRange) != nil {
                    flush()
                    continue
                }
            }

            if currentStart != nil {
                currentText.append(line)
            }
        }

        flush()
        return items
    }
}

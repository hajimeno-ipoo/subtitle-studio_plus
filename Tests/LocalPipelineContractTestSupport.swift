import Foundation

enum ContractTestError: LocalizedError {
    case missingFile(String)
    case missingToken(file: String, token: String)
    case missingAnyToken(file: String, candidates: [String])
    case invalidTokenOrder(file: String, first: String, second: String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let file):
            return "Required file is missing: \(file)"
        case .missingToken(let file, let token):
            return "Required token is missing in \(file): \(token)"
        case .missingAnyToken(let file, let candidates):
            return "None of required tokens exist in \(file): \(candidates.joined(separator: ", "))"
        case .invalidTokenOrder(let file, let first, let second):
            return "Token order is invalid in \(file): \(first) should appear before \(second)"
        }
    }
}

func projectRootURL(from filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func loadProjectFile(_ relativePath: String, from filePath: String = #filePath) throws -> String {
    let url = projectRootURL(from: filePath).appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ContractTestError.missingFile(relativePath)
    }
    var lastError: Error?
    for _ in 0..<20 {
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let source = String(data: data, encoding: .utf8) else {
                throw ContractTestError.missingFile(relativePath)
            }
            return source
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == 4 {
            lastError = error
            Thread.sleep(forTimeInterval: 0.1)
        } catch {
            throw error
        }
    }
    throw lastError ?? ContractTestError.missingFile(relativePath)
}

func requireContains(_ source: String, token: String, file: String) throws {
    guard source.contains(token) else {
        throw ContractTestError.missingToken(file: file, token: token)
    }
}

func requireContainsAny(_ source: String, candidates: [String], file: String) throws {
    guard candidates.contains(where: { source.contains($0) }) else {
        throw ContractTestError.missingAnyToken(file: file, candidates: candidates)
    }
}

func requireOrdered(_ source: String, first: String, second: String, file: String) throws {
    guard
        let firstRange = source.range(of: first),
        let secondRange = source.range(of: second)
    else {
        throw ContractTestError.invalidTokenOrder(file: file, first: first, second: second)
    }
    guard firstRange.lowerBound < secondRange.lowerBound else {
        throw ContractTestError.invalidTokenOrder(file: file, first: first, second: second)
    }
}

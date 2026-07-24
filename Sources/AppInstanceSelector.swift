import Foundation

enum AppInstanceSelector {
    struct Descriptor: Equatable {
        let pid: Int32
        let bundleURL: URL?
    }

    enum Decision: Equatable {
        case proceed
        case terminateSelf(preferred: Descriptor)
        case terminateOthers([Int32])
    }

    static func decide(current: Descriptor, others: [Descriptor]) -> Decision {
        let competitors = others.filter { $0.pid != current.pid }
        guard !competitors.isEmpty else {
            return .proceed
        }

        let currentRank = installRank(for: current.bundleURL)
        let bestOther = competitors.max {
            installRank(for: $0.bundleURL) < installRank(for: $1.bundleURL)
        }

        guard let bestOther else {
            return .proceed
        }

        let otherRank = installRank(for: bestOther.bundleURL)
        if currentRank > otherRank {
            return .terminateOthers(competitors.map(\.pid))
        }

        return .terminateSelf(preferred: bestOther)
    }

    private static func installRank(for bundleURL: URL?) -> Int {
        guard let bundleURL else { return 0 }

        let standardizedPath = bundleURL.standardizedFileURL.path
        if standardizedPath.hasPrefix("/Applications/") || standardizedPath == "/Applications" {
            return 2
        }
        if standardizedPath.hasPrefix(userApplicationsPath + "/") || standardizedPath == userApplicationsPath {
            return 1
        }
        return 0
    }

    private static let userApplicationsPath: String = {
        FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first?
            .standardizedFileURL.path ?? ""
    }()
}

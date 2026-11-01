public import Foundation

/// Nightjar's update check (`update_check.rs`, after Moonlight V+ PC's AutoUpdateChecker),
/// pointed at Mystic's releases: a stable release newer than this build is offered with a link
/// to its page. Nothing is downloaded or installed.
public enum UpdateCheck {
    public static let latestRelease = URL(string:"https://api.github.com/repos/neer2005/Mystic/releases/latest")!

    public struct Release: Equatable, Sendable {
        public let version: String
        /// The release page on github.com.
        public let page: URL
    }

    /// A version's numbers and pre-release part ("rc.1" in 1.0.0-rc.1); a leading `v` is allowed.
    static func parse(_ text: String) -> (numbers: [UInt64], prerelease: String?)? {
        var text=text.trimmingCharacters(in:.whitespaces)
        if text.hasPrefix("v") { text.removeFirst() }
        let split=text.split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        let core=split[0].split(separator:"+",omittingEmptySubsequences:false)[0]
        let parts=core.split(separator:".",omittingEmptySubsequences:false).map { UInt64($0) }
        guard (2...3).contains(parts.count),parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers=parts.compactMap { $0 }+(parts.count == 2 ? [0] : [])
        let prerelease=split.count == 2 && !split[1].isEmpty ? String(split[1]) : nil
        return (numbers,prerelease)
    }
    /// Whether `tag` is a stable release newer than `current`. A pre-release build is older than
    /// its own final version, as in SemVer.
    public static func newerStable(tag: String,current: String) -> Bool {
        guard let latest=parse(tag),latest.prerelease == nil,let running=parse(current) else { return false }
        return latest.numbers.lexicographicallyPrecedes(running.numbers) == false
            && (latest.numbers != running.numbers || running.prerelease != nil)
    }
    /// The release GitHub answered, if it is an update for `current`. Drafts and pre-releases
    /// never are, and only a github.com page is offered.
    public static func offer(_ json: Data,current: String) throws -> Release? {
        guard let value=try? JSONSerialization.jsonObject(with:json) as? [String:Any] else { throw Failure("unreadable release") }
        guard let tag=value["tag_name"] as? String else { throw Failure("the release has no tag") }
        if value["draft"] as? Bool == true || value["prerelease"] as? Bool == true || !newerStable(tag:tag,current:current) { return nil }
        guard let text=value["html_url"] as? String,text.hasPrefix("https://github.com/"),let page=URL(string:text) else {
            throw Failure("the release has no page")
        }
        return Release(version:tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,page:page)
    }
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description=description }
    }
}

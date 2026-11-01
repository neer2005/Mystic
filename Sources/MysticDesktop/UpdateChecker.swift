import AppKit
import Foundation
import Observation
import MysticCore

/// Once per launch, when the setting is on, asks GitHub for Mystic's latest release and offers
/// a newer stable one with a link to its page, as Nightjar's desktop client does. Failures stay
/// out of the way: anonymous GitHub requests are rate limited, so they only show in Settings.
@MainActor @Observable
public final class UpdateChecker {
    /// A newer release, until it is opened or dismissed.
    public private(set) var found: UpdateCheck.Release?
    /// What the last check found, for Settings.
    public private(set) var status="Not checked yet"
    @ObservationIgnored private var started=false
    @ObservationIgnored let fetch: @Sendable (URLRequest) async throws -> (Data,URLResponse)
    init(fetch: @escaping @Sendable (URLRequest) async throws -> (Data,URLResponse) = { try await URLSession.shared.data(for:$0) }) {
        self.fetch=fetch
    }
    /// This build's version; a build without one (from `swift run`) is never offered updates.
    nonisolated static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
    }

    func startOnce(enabled: Bool,version: String? = UpdateChecker.currentVersion) async {
        guard enabled,!started else { return }
        started=true
        guard let version else { status="Not checked: this build has no version";return }
        status="Checking…"
        var request=URLRequest(url:UpdateCheck.latestRelease,timeoutInterval:15)
        request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
        request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version")
        request.setValue("Mystic/\(version) (macOS)",forHTTPHeaderField:"User-Agent")
        do {
            let (data,response)=try await fetch(request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                found=try UpdateCheck.offer(data,current:version)
                status=found.map { "Mystic \($0.version) is available" } ?? "Mystic \(version) is up to date"
            case 404: status="No release has been published yet"
            case 403,429: status="GitHub's rate limit was reached; Mystic checks again next launch"
            case let code: status="GitHub answered HTTP \(code)"
            }
        } catch { status="The check failed: \(error.localizedDescription)" }
    }
    public func openPage() {
        if let found { NSWorkspace.shared.open(found.page) }
        found=nil
    }
    public func dismiss() { found=nil }
}

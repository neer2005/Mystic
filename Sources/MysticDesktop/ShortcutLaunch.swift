import Foundation

/// A stream started from outside the app, as Nightjar's `cli.rs` takes it from game frontends
/// (ES-DE, Pegasus, Playnite): `--host <name|uuid> [--app <name|uuid>] [--quit-on-exit]`, or the
/// same as a `mystic://stream?host=…&app=…&quit-on-exit=1` link.
public struct ShortcutLaunch: Equatable, Sendable {
    public var host: String
    public var app: String?
    /// Quit Mystic when this stream ends, so the frontend gets its window back.
    public var quitOnExit=false
    /// Links can come from any web page, so they ask before starting; the command line does not.
    public var fromLink=false
    public init(host: String,app: String? = nil,quitOnExit: Bool = false,fromLink: Bool = false) {
        self.host=host;self.app=app;self.quitOnExit=quitOnExit;self.fromLink=fromLink
    }

    public enum Arguments: Equatable, Sendable {
        /// No launch flags: an ordinary start.
        case none
        case version,help
        case launch(ShortcutLaunch)
        /// A wrong command line; Nightjar exits with 64 (EX_USAGE).
        case invalid(String)
    }
    public static let usage="usage: Mystic [--version | --host <name|uuid> [--app <name|uuid>] [--quit-on-exit]]"
    public static let scheme="mystic"

    /// The arguments after the program name. `--name value` and `--name=value` both work.
    /// macOS's own single-dash arguments (`-NSDocumentRevisionsDebugMode YES`, `-psn_…`) are
    /// skipped with their value.
    public static func parse(arguments: [String]) -> Arguments {
        var host: String?,app: String?,quitOnExit=false,sawFlag=false
        var index=0
        while index < arguments.count {
            let argument=arguments[index];index += 1
            guard argument.hasPrefix("--") else {
                if argument.hasPrefix("-"),!["-h"].contains(argument) {
                    if index < arguments.count,!arguments[index].hasPrefix("-") { index += 1 }
                    continue
                }
                if argument == "-h" { return .help }
                return .invalid("unexpected argument \(argument)\n\(usage)")
            }
            sawFlag=true
            let parts=argument.split(separator:"=",maxSplits:1).map(String.init)
            let flag=parts[0],inline=parts.count == 2 ? parts[1] : nil
            switch flag {
            case "--help" where inline == nil: return .help
            case "--version" where inline == nil: return .version
            case "--quit-on-exit" where inline == nil: quitOnExit=true
            case "--host","--app":
                let value: String
                if let inline { value=inline }
                else if index < arguments.count,!arguments[index].hasPrefix("--") { value=arguments[index];index += 1 }
                else { return .invalid("\(flag) needs a value\n\(usage)") }
                let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .invalid("\(flag) needs a value\n\(usage)") }
                if flag == "--host" {
                    guard host == nil else { return .invalid("--host given twice\n\(usage)") }
                    host=trimmed
                } else {
                    guard app == nil else { return .invalid("--app given twice\n\(usage)") }
                    app=trimmed
                }
            default: return .invalid("unknown option \(argument)\n\(usage)")
            }
        }
        guard sawFlag else { return .none }
        guard let host else { return .invalid("--app and --quit-on-exit need --host\n\(usage)") }
        return .launch(ShortcutLaunch(host:host,app:app,quitOnExit:quitOnExit))
    }

    /// A `mystic://stream` link, or nil when it is not one.
    public static func parse(url: URL) -> ShortcutLaunch? {
        guard url.scheme?.lowercased() == scheme,url.host()?.lowercased() == "stream",
              let items=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in:.whitespacesAndNewlines).nilIfEmpty
        }
        guard let host=value("host") else { return nil }
        let quit=["1","true","yes"].contains(value("quit-on-exit")?.lowercased() ?? "")
        return ShortcutLaunch(host:host,app:value("app"),quitOnExit:quit,fromLink:true)
    }

    /// This launch as a link.
    public var link: URL {
        var components=URLComponents()
        components.scheme=Self.scheme;components.host="stream"
        components.queryItems=[URLQueryItem(name:"host",value:host)]
            + (app.map { [URLQueryItem(name:"app",value:$0)] } ?? [])
            + (quitOnExit ? [URLQueryItem(name:"quit-on-exit",value:"1")] : [])
        return components.url!
    }
    /// This launch as a command line for `executable`, quoted for a POSIX shell.
    public func commandLine(executable: String) -> String {
        func quote(_ value: String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        var parts=[quote(executable),"--host",quote(host)]
        if let app { parts += ["--app",quote(app)] }
        if quitOnExit { parts.append("--quit-on-exit") }
        return parts.joined(separator:" ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation

/// What a command run on its own exec channel printed and how it exited.
struct RemoteCommandResult {
    var exitCode: Int32
    var output: String
    var errorOutput: String

    var succeeded: Bool { exitCode == 0 }

    /// The tool a script reported missing with `pick`, if any.
    var missingTool: String? {
        guard exitCode == 127, let range = errorOutput.range(of: "cterm-missing:") else { return nil }
        let tool = errorOutput[range.upperBound...].prefix { !$0.isWhitespace }
        return tool.isEmpty ? nil : String(tool)
    }

    /// A message for an alert: an install hint for a missing tool, else the
    /// last lines the command printed.
    var failureMessage: String {
        if let tool = missingTool {
            return RemoteCommands.installHint(for: tool)
        }
        let text = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? output : errorOutput
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if lines.isEmpty { return "命令退出码 \(exitCode)。" }
        return lines.suffix(6).joined(separator: "\n")
    }
}

/// Archive kinds the panel can extract, recognised by file name.
enum ArchiveFormat: CaseIterable {
    case zip, tar, tarGzip, tarBzip2, tarXz, tarZstd, gzip, bzip2, xz, zstd, sevenZip, rar

    /// Longer suffixes first, so "a.tar.gz" isn't taken for plain gzip.
    private static let suffixes: [(String, ArchiveFormat)] = [
        (".tar.gz", .tarGzip), (".tgz", .tarGzip),
        (".tar.bz2", .tarBzip2), (".tbz2", .tarBzip2), (".tbz", .tarBzip2),
        (".tar.xz", .tarXz), (".txz", .tarXz),
        (".tar.zst", .tarZstd), (".tzst", .tarZstd),
        (".tar", .tar), (".zip", .zip), (".7z", .sevenZip), (".rar", .rar),
        (".gz", .gzip), (".bz2", .bzip2), (".xz", .xz), (".zst", .zstd)
    ]

    static func detect(_ name: String) -> (format: ArchiveFormat, stem: String)? {
        let lower = name.lowercased()
        for (suffix, format) in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return (format, String(name.dropLast(suffix.count)))
        }
        return nil
    }

    /// One compressed file rather than a folder of entries.
    var isSingleFile: Bool {
        switch self {
        case .gzip, .bzip2, .xz, .zstd: return true
        default: return false
        }
    }
}

/// Shell scripts for the file operations SFTP itself can't do. Each runs
/// under `sh -c`, whatever the user's login shell is.
enum RemoteCommands {
    /// `pick a b` prints the first of the tools that exists, or reports the
    /// first as missing on stderr for `missingTool`.
    private static let prelude = """
        pick() { for t in "$@"; do if command -v "$t" >/dev/null 2>&1; then echo "$t"; return 0; fi; done; \
        echo "cterm-missing:$1" >&2; return 1; }
        """

    private static func q(_ value: String) -> String { RemotePath.shellQuoted(value) }

    private static func script(_ body: String) -> String {
        "sh -c " + q(prelude + "\n" + body)
    }

    static func chmod(_ paths: [String], mode: UInt32, recursive: Bool) -> String {
        let octal = String(mode & 0o7777, radix: 8)
        let flags = recursive ? "-R " : ""
        return script("chmod \(flags)-- \(octal) " + paths.map(q).joined(separator: " "))
    }

    /// Zips `names` (all inside `directory`) into `archiveName` beside them.
    static func zip(_ names: [String], in directory: String, into archiveName: String) -> String {
        let items = names.map { q("./" + $0) }.joined(separator: " ")
        return script("""
            pick zip >/dev/null || exit 127
            cd \(q(directory)) && zip -r -q -y \(q(archiveName)) \(items)
            """)
    }

    /// Extracts `archive` into the folder `destination`, creating it. A
    /// single compressed file is written to `destination/output` instead.
    static func extract(_ archive: String, format: ArchiveFormat, into destination: String,
                        output: String) -> String {
        let a = q(archive)
        let d = q(destination)
        let body: String
        switch format {
        case .zip:
            body = "pick unzip >/dev/null || exit 127\nmkdir -p \(d) && unzip -o -q \(a) -d \(d)"
        case .tar:
            body = "pick tar >/dev/null || exit 127\nmkdir -p \(d) && tar -xf \(a) -C \(d)"
        case .tarGzip:
            body = "pick tar >/dev/null || exit 127\npick gzip >/dev/null || exit 127\n"
                + "mkdir -p \(d) && tar -xzf \(a) -C \(d)"
        case .tarBzip2:
            body = "pick tar >/dev/null || exit 127\npick bzip2 >/dev/null || exit 127\n"
                + "mkdir -p \(d) && tar -xjf \(a) -C \(d)"
        case .tarXz:
            body = "pick tar >/dev/null || exit 127\npick xz >/dev/null || exit 127\n"
                + "mkdir -p \(d) && tar -xJf \(a) -C \(d)"
        case .tarZstd:
            // Not every tar knows zstd; test first since a pipe hides
            // the decompressor's exit status.
            body = "pick tar >/dev/null || exit 127\npick zstd >/dev/null || exit 127\n"
                + "zstd -tq \(a) && mkdir -p \(d) && zstd -dcq \(a) | tar -xf - -C \(d)"
        case .gzip, .bzip2, .xz, .zstd:
            let tool: String
            switch format {
            case .gzip: tool = "gzip"
            case .bzip2: tool = "bzip2"
            case .xz: tool = "xz"
            default: tool = "zstd"
            }
            let out = q(RemotePath.join(destination, output))
            body = "pick \(tool) >/dev/null || exit 127\n"
                + "mkdir -p \(d) && \(tool) -dc \(a) > \(out) || { rm -f \(out); exit 1; }"
        case .sevenZip:
            body = "Z=$(pick 7z 7za 7zz) || exit 127\nmkdir -p \(d) && \"$Z\" x -y -bd \(a) -o\(d) >/dev/null"
        case .rar:
            body = """
                if command -v unrar >/dev/null 2>&1; then
                  mkdir -p \(d) && unrar x -o+ -y -idq \(a) \(q(destination.hasSuffix("/") ? destination : destination + "/"))
                else
                  Z=$(pick 7z 7zz 7za 2>/dev/null) || { echo "cterm-missing:unrar" >&2; exit 127; }
                  mkdir -p \(d) && "$Z" x -y -bd \(a) -o\(d) >/dev/null
                fi
                """
        }
        return script(body)
    }

    private static let packages: [String: (apt: String, yum: String)] = [
        "xz": ("xz-utils", "xz"),
        "7z": ("p7zip-full", "p7zip p7zip-plugins"),
        "unrar": ("unrar", "unrar")
    ]

    static func installHint(for tool: String) -> String {
        let package = packages[tool] ?? (tool, tool)
        return """
            服务器上没有安装 \(tool)，请先安装后再试。

            Debian / Ubuntu：sudo apt install \(package.apt)
            CentOS / RHEL：sudo yum install \(package.yum)
            """
    }
}

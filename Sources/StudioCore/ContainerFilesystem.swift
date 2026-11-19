import Foundation

public struct ContainerFileEntry: Identifiable, Sendable, Equatable {
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public var id: String { name }
}

public struct ContainerTextFile: Sendable {
    public let text: String
    public let checksum: String
}

public enum ContainerFilesystem {
    public static let maximumFileBytes = 65_536
    // All paths and file contents are positional arguments, never interpolated into shell source.
    public static let listScript = #"""
    cd -- "$1" || exit
    for entry in .[!.]* ..?* *; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      kind=f
      [ -d "$entry" ] && kind=d
      [ -L "$entry" ] && kind=l
      printf '%s\000%s\000' "$kind" "$entry"
    done
    """#
    public static let readScript = #"""
    [ -f "$1" ] || { printf 'Select a regular text file.' >&2; exit 1; }
    size=$(wc -c < "$1") || exit
    [ "$size" -le 65536 ] || { printf 'Files larger than 64 KB can be edited in the terminal.' >&2; exit 1; }
    before=$(cksum < "$1") || exit
    printf '%s\000' "$before"
    cat -- "$1" || exit
    after=$(cksum < "$1") || exit
    [ "$before" = "$after" ] || { printf 'File changed while reading. Reload it.' >&2; exit 1; }
    """#
    public static let saveScript = #"""
    [ -f "$1" ] && [ ! -L "$1" ] || { printf 'Saving requires a regular file, not a symbolic link.' >&2; exit 1; }
    current=$(cksum < "$1") || exit
    [ "$current" = "$2" ] || { printf 'File changed in the container. Reload before saving.' >&2; exit 1; }
    tmp=$(mktemp "${1}.studio-XXXXXX") || exit
    trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
    cp -p -- "$1" "$tmp" || exit
    printf '%s' "$3" > "$tmp" || exit
    current=$(cksum < "$1") || exit
    [ "$current" = "$2" ] || { printf 'File changed in the container. Reload before saving.' >&2; exit 1; }
    mv -f -- "$tmp" "$1" || exit
    cksum < "$1"
    """#

    public static func arguments(id: String, script: String, values: [String]) -> [String] {
        ["exec", "--", id, "/bin/sh", "-c", script, "studio-files"] + values
    }

    public static func decodeEntries(_ data: Data) throws -> [ContainerFileEntry] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 2 == 1, fields.last?.isEmpty == true else { throw CocoaError(.fileReadCorruptFile) }
        var entries: [ContainerFileEntry] = []
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            guard let kind = String(data: fields[index], encoding: .utf8), let name = String(data: fields[index + 1], encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            entries.append(ContainerFileEntry(name: name, isDirectory: kind == "d", isSymbolicLink: kind == "l"))
        }
        return entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func decodeText(_ data: Data) throws -> ContainerTextFile {
        guard let separator = data.firstIndex(of: 0), let checksum = String(data: data[..<separator], encoding: .utf8),
              let text = String(data: data[data.index(after: separator)...], encoding: .utf8), !text.contains("\0") else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return ContainerTextFile(text: text, checksum: checksum)
    }
}

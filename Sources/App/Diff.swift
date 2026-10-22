import Foundation

struct DiffLine: Codable, Hashable {
    enum Kind: String, Codable { case same, added, removed }
    var kind: Kind
    var text: String
}

/// A file change the model made (or wants to make): line counts plus a compact diff.
struct FileDiff: Codable, Hashable {
    var path: String
    var added: Int
    var removed: Int
    var isNewFile: Bool
    var lines: [DiffLine]   // changed lines with a little context, capped in size

    var fileName: String { (path as NSString).lastPathComponent }
}

enum Differ {
    /// Line diff between two texts (longest-common-subsequence), trimmed to the changed hunks.
    static func diff(path: String, old: String?, new: String, context: Int = 2, maxLines: Int = 400) -> FileDiff {
        let a = old.map { $0.components(separatedBy: "\n") } ?? []
        let b = new.components(separatedBy: "\n")
        var lines: [DiffLine]

        if a.count * b.count > 4_000_000 {
            // Too big for a full LCS table: report as replaced.
            lines = a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
        } else {
            let n = a.count, m = b.count
            var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
            if n > 0 && m > 0 {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    for j in stride(from: m - 1, through: 0, by: -1) {
                        table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
            lines = []
            var i = 0, j = 0
            while i < n && j < m {
                if a[i] == b[j] { lines.append(DiffLine(kind: .same, text: a[i])); i += 1; j += 1 }
                else if table[i + 1][j] >= table[i][j + 1] { lines.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
                else { lines.append(DiffLine(kind: .added, text: b[j])); j += 1 }
            }
            while i < n { lines.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
            while j < m { lines.append(DiffLine(kind: .added, text: b[j])); j += 1 }
        }

        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count

        // Keep only changed lines plus a few lines of context around them.
        var keep = [Bool](repeating: false, count: lines.count)
        for (k, l) in lines.enumerated() where l.kind != .same {
            for c in max(0, k - context)...min(lines.count - 1, k + context) { keep[c] = true }
        }
        var trimmed: [DiffLine] = []
        var skipped = false
        for (k, l) in lines.enumerated() {
            if keep[k] { trimmed.append(l); skipped = false }
            else if !skipped { trimmed.append(DiffLine(kind: .same, text: "⋯")); skipped = true }
        }
        if trimmed.count > maxLines { trimmed = Array(trimmed.prefix(maxLines)) + [DiffLine(kind: .same, text: "⋯ \(trimmed.count - maxLines) more lines")] }
        return FileDiff(path: path, added: added, removed: removed, isNewFile: old == nil, lines: trimmed)
    }
}

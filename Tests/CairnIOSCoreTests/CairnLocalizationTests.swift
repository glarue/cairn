import Foundation
import Testing
import CairnCore
@testable import CairnIOSCore

@Suite("Localization startup regression", .serialized)
struct CairnLocalizationTests {
    /// A duplicate key inside a Swift dictionary *literal* compiles fine but
    /// traps on first access. Scanning the source catches it before runtime.
    @Test("Translation dictionary has no duplicate keys")
    func noDuplicateDictionaryKeys() throws {
        let url = try #require(Self.translationSourceURL(), "CairnLocalization.swift not found on disk")
        let source = try String(contentsOf: url, encoding: .utf8)
        var seen = Set<String>()
        var duplicates = Set<String>()
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Dictionary entries are single-line `"key": "value",` rows.
            guard trimmed.hasPrefix("\""), trimmed.hasSuffix(","),
                  let colon = trimmed.range(of: "\": ") else { continue }
            let key = String(trimmed.dropFirst().prefix(upTo: colon.lowerBound))
            if !seen.insert(key).inserted { duplicates.insert(key) }
        }
        #expect(seen.count > 500, "Expected the full dictionary to be scanned")
        #expect(duplicates.isEmpty, "Duplicate translation keys will trap at startup: \(duplicates.sorted())")
    }

    private static func translationSourceURL() -> URL? {
        // `#filePath` points at Tests/CairnIOSCoreTests/… — walk up to the
        // package root and resolve the localization source.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<4 {
            let candidate = dir
                .appendingPathComponent("Sources/CairnIOSCore/UI/CairnLocalization.swift")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Chinese lookup initializes the dictionary without trapping; language switching preserves fallback")
    func dictionaryInitializationAndLanguageSwitching() {
        let originalLanguage = CairnL10n.currentLanguage
        defer { CairnL10n.currentLanguage = originalLanguage }

        // A duplicate dictionary-literal key traps on the first Chinese lookup,
        // not during compilation. Exercise the same path used by app startup.
        CairnL10n.currentLanguage = .chineseSimplified
        #expect(CairnL10n.text("Status") == "状态")
        #expect(CairnL10n.text("Backlog alert") == "待删积压提醒")
        #expect(CairnL10n.text("QUICK SETTINGS") == "快捷设置")
        #expect(CairnL10n.text("Indexing your library") == "索引照片库")
        #expect(CairnL10n.text("processed") == "已处理")
        #expect(CairnL10n.text("ELAPSED") == "已耗时")
        #expect(CairnL10n.text("REMAINING") == "预估剩余")
        #expect(CairnL10n.text("Start indexing") == "开始索引")
        #expect(CairnL10n.text("Resume indexing") == "继续索引")
        #expect(CairnL10n.text("Scan options") == "扫描选项")
        #expect(CairnL10n.text("Sync detail") == "同步详情")
        #expect(CairnL10n.text("Deferred queue") == "推迟处理队列")
        #expect(CairnL10n.text("Clear hash cache?") == "清空哈希缓存？")
        #expect(CairnL10n.text("Rescan library?") == "重新扫描照片库？")
        #expect(CairnL10n.text("Reset index?") == "重置索引？")
        #expect(CairnL10n.text("Disconnect server?") == "断开服务器连接？")
        #expect(CairnL10n.text("Find missed deletions") == "查找遗漏的删除")
        #expect(CairnL10n.text("Archived history") == "归档历史")
        #expect(CairnL10n.text("Sign in for incremental sync") == "登录以开启增量同步")
        #expect(CairnL10n.text("No user-created albums") == "未找到用户创建的相册")
        #expect(CairnL10n.text("Hiding automatically in a few seconds. Keep it secret. Keep it safe.") == "将在几秒内自动隐藏。请妥善保管。")
        #expect(CairnL10n.text("Server returned 401. Your key may have been revoked or expired. Paste a new one in Settings.") == "服务器返回 401。你的密钥可能已被撤销或过期，请在“设置”中粘贴新的密钥。")
        #expect(CairnL10n.text("First sync is a dry-run") == "首次同步为试运行")
        #expect(CairnL10n.text("Safety rail tripped") == "安全防线已触发")
        #expect(CairnL10n.text("Run metadata") == "运行元数据")
        #expect(CairnL10n.text("Server-side breadcrumb") == "服务器端面包屑标签")
        #expect(CairnL10n.text("Trash run") == "移入废纸篓运行")
        #expect(CairnL10n.text("Deleted together") == "一同删除")
        #expect(CairnL10n.text("Preview only — nothing touched") == "仅供预览 — 未改动任何内容")
        #expect(CairnL10n.text("From run ") == "来自运行 ")
        #expect(CairnL10n.text("Remove") == "移除")
        #expect(CairnL10n.text("Loading…") == "加载中…")
        #expect(CairnL10n.text("Recent") == "最近")
        #expect(CairnL10n.text("By type") == "按类型")
        #expect(CairnL10n.text("Signing in") == "登录中")
        #expect(CairnL10n.text("unknown-localization-key") == "unknown-localization-key")

        CairnL10n.currentLanguage = .english
        #expect(CairnL10n.text("Status") == "Status")
        #expect(CairnL10n.text("Backlog alert") == "Backlog alert")

        CairnL10n.currentLanguage = .chineseSimplified
        #expect(CairnL10n.text("Status") == "状态")
    }
}

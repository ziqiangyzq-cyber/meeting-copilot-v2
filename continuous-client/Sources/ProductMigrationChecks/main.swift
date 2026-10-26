import Foundation
import ClientRuntime

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let text) = self { return text }; return "" }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

@main
struct ProductMigrationChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: "/tmp/meeting-copilot-product-migration-check", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let source = support.appendingPathComponent(LegacyProductMigration.legacyDataDirectoryName, isDirectory: true)
        let destination = support.appendingPathComponent(LegacyProductMigration.destinationDirectoryName, isDirectory: true)
        let previousV2 = support.appendingPathComponent(LegacyProductMigration.legacyV2DataDirectoryName, isDirectory: true)
        let oldProduct = root.appendingPathComponent("资产库/AI成品/Foresight Meeting", isDirectory: true)
        let newProduct = root.appendingPathComponent("资产库/AI成品/Meeting Copilot", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: oldProduct.appendingPathComponent("运行依赖/qwen-asr/model"), withIntermediateDirectories: true)

        try Data(#"{"schemaVersion":1,"asr":{"modelPath":"\#(oldProduct.path)/运行依赖/qwen-asr/model"}}"#.utf8)
            .write(to: source.appendingPathComponent("settings.json"))
        try Data("meeting archive".utf8).write(to: source.appendingPathComponent("sessions.json"))
        try Data().write(to: source.appendingPathComponent("sessions.json.lock"))
        try Data("draft".utf8).write(to: source.appendingPathComponent("meeting-drafts.json"))

        let sourceSettings = try Data(contentsOf: source.appendingPathComponent("settings.json"))
        let report = try LegacyProductMigration.migrateIfNeeded(
            destination: destination,
            sourceDirectory: source,
            legacyProductRoots: [oldProduct],
            destinationProductRoot: newProduct,
            fileManager: fm
        )
        try require(report?.copiedFiles == 3, "expected three copied data files, got \(report?.copiedFiles ?? -1)")
        try require(fm.fileExists(atPath: destination.appendingPathComponent("settings.json").path),
                    "settings file missing")
        try require(fm.fileExists(atPath: destination.appendingPathComponent("sessions.json").path),
                    "sessions file missing")
        try require(fm.fileExists(atPath: destination.appendingPathComponent("meeting-drafts.json").path),
                    "draft file missing")
        try require(!fm.fileExists(atPath: destination.appendingPathComponent("sessions.json.lock").path),
                    "lock file must be excluded")
        let sourceAfter = try Data(contentsOf: source.appendingPathComponent("settings.json"))
        try require(sourceAfter == sourceSettings,
                    "legacy settings must remain byte-identical")
        try require(fm.fileExists(atPath: source.appendingPathComponent("sessions.json.lock").path),
                    "legacy lock file must remain untouched")
        let copied = try JSONSerialization.jsonObject(
            with: Data(contentsOf: destination.appendingPathComponent("settings.json"))) as? [String: Any]
        let asr = copied?["asr"] as? [String: Any]
        try require(asr?["modelPath"] as? String == newProduct.appendingPathComponent("运行依赖/qwen-asr/model").path,
                    "copied model path must point to the new product directory")
        try require(fm.fileExists(atPath: destination.appendingPathComponent(LegacyProductMigration.migrationMarkerName).path),
                    "migration marker missing")
        let second = try LegacyProductMigration.migrateIfNeeded(
            destination: destination, sourceDirectory: source,
            legacyProductRoots: [oldProduct], destinationProductRoot: newProduct, fileManager: fm)
        try require(second == nil, "existing destination must never be overwritten")

        // Simulate a settings file written by the previous migrated build:
        // the destination exists, but paths still point at the old folder.
        let existingSettings: [String: Any] = [
            "schemaVersion": 1,
            "asr": [
                "modelPath": oldProduct.appendingPathComponent("运行依赖/qwen-asr/model").path,
                "runtimePath": oldProduct.appendingPathComponent("运行依赖/qwen-asr/.venv-local").path
            ],
            "displayName": "Foresight Meeting",
            "futureUnknownKey": ["text": "Foresight Meeting", "pathLike": "/tmp/not-a-product-path"]
        ]
        try JSONSerialization.data(withJSONObject: existingSettings, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("settings.json"))
        let sourceBeforeNormalize = try Data(contentsOf: source.appendingPathComponent("settings.json"))
        let didNormalize = try LegacyProductMigration.normalizeExistingSettingsPaths(
            destination: destination,
            legacyProductRoots: [oldProduct],
            destinationProductRoot: newProduct,
            fileManager: fm)
        try require(didNormalize, "existing destination paths were not normalized")
        let normalizedData = try Data(contentsOf: destination.appendingPathComponent("settings.json"))
        let normalized = try JSONSerialization.jsonObject(with: normalizedData) as? [String: Any]
        let normalizedASR = normalized?["asr"] as? [String: Any]
        try require(normalizedASR?["modelPath"] as? String ==
                    newProduct.appendingPathComponent("运行依赖/qwen-asr/model").path,
                    "existing model path did not move to the new product root")
        try require(normalizedASR?["runtimePath"] as? String ==
                    newProduct.appendingPathComponent("运行依赖/qwen-asr/.venv-local").path,
                    "existing runtime path did not move to the new product root")
        try require(normalized?["displayName"] as? String == "Foresight Meeting",
                    "non-path string was rewritten")
        let unknown = normalized?["futureUnknownKey"] as? [String: Any]
        try require(unknown?["text"] as? String == "Foresight Meeting" &&
                    unknown?["pathLike"] as? String == "/tmp/not-a-product-path",
                    "unknown keys or non-product paths changed")
        let sourceAfterNormalize = try Data(contentsOf: source.appendingPathComponent("settings.json"))
        try require(sourceAfterNormalize == sourceBeforeNormalize,
                    "normalization modified the old source settings")
        let normalizedAgain = try LegacyProductMigration.normalizeExistingSettingsPaths(
            destination: destination,
            legacyProductRoots: [oldProduct],
            destinationProductRoot: newProduct,
            fileManager: fm)
        let dataAfterSecondNormalization = try Data(contentsOf: destination.appendingPathComponent("settings.json"))
        try require(!normalizedAgain && dataAfterSecondNormalization == normalizedData,
                    "second normalization was not an exact no-op")

        print("PASS legacy data copied, locks excluded, paths rewritten, source untouched, rerun refused")
        print("PASS existing destination normalization, unknown keys preserved, second pass no-op")

        // The public identity migrates the pre-public v2 directory independently and preserves its source.
        let publicRoot = root.appendingPathComponent("public-support", isDirectory: true)
        let publicDestination = publicRoot.appendingPathComponent(ProductIdentity.dataDirectoryName, isDirectory: true)
        try fm.createDirectory(at: previousV2, withIntermediateDirectories: true)
        try Data("pre-public archive".utf8).write(to: previousV2.appendingPathComponent("sessions.json"))
        try Data().write(to: previousV2.appendingPathComponent("sessions.json.lock"))
        let publicReport = try LegacyProductMigration.migratePreviousV2DataIfNeeded(
            destination: publicDestination,
            sourceDirectory: previousV2,
            fileManager: fm
        )
        try require(publicReport?.copiedFiles == 1, "pre-public v2 migration copied the wrong file count")
        try require(fm.fileExists(atPath: publicDestination.appendingPathComponent("sessions.json").path),
                    "pre-public v2 archive missing from public destination")
        try require(!fm.fileExists(atPath: publicDestination.appendingPathComponent("sessions.json.lock").path),
                    "pre-public v2 lock file must be excluded")
        try require(fm.fileExists(atPath: previousV2.appendingPathComponent("sessions.json").path),
                    "pre-public v2 source must be preserved")
        try require(fm.fileExists(atPath: publicDestination.appendingPathComponent(
                    LegacyProductMigration.previousV2MigrationMarkerName).path),
                    "pre-public v2 migration marker missing")
        let publicSecond = try LegacyProductMigration.migratePreviousV2DataIfNeeded(
            destination: publicDestination,
            sourceDirectory: previousV2,
            fileManager: fm
        )
        try require(publicSecond == nil, "existing public destination must never be overwritten")
        print("PASS pre-public v2 data copied, locks excluded, source preserved, rerun refused")
        print("PRODUCT_MIGRATION_CHECKS_COMPLETE")
    }
}

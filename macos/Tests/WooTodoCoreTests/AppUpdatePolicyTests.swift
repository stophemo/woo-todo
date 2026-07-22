import Foundation
import Testing
@testable import WooTodoCore

struct AppUpdatePolicyTests {
    @Test("解析 GitHub 标签并忽略构建元数据")
    func parsesReleaseTags() {
        #expect(AppVersion("v0.1.4")?.description == "0.1.4")
        #expect(AppVersion("  V2.3.4+build.9  ")?.description == "2.3.4")
        #expect(AppVersion("1.0.0-rc.2")?.description == "1.0.0-rc.2")
    }

    @Test("拒绝不完整或不符合 SemVer 的版本")
    func rejectsMalformedVersions() {
        #expect(AppVersion("1.2") == nil)
        #expect(AppVersion("1.2.3.4") == nil)
        #expect(AppVersion("01.2.3") == nil)
        #expect(AppVersion("1.2.3-") == nil)
        #expect(AppVersion("1.2.3-rc.01") == nil)
        #expect(AppVersion("release-1.2.3") == nil)
    }

    @Test("更新检查只接受规范的正式版本标签")
    func acceptsOnlyStableReleaseTags() {
        #expect(
            AppUpdatePolicy.stableReleaseVersion(fromGitHubTag: "v1.2.3")?.description
                == "1.2.3"
        )
        #expect(AppUpdatePolicy.stableReleaseVersion(fromGitHubTag: "1.2.3") == nil)
        #expect(AppUpdatePolicy.stableReleaseVersion(fromGitHubTag: "V1.2.3") == nil)
        #expect(AppUpdatePolicy.stableReleaseVersion(fromGitHubTag: "v1.2.3-rc.1") == nil)
        #expect(AppUpdatePolicy.stableReleaseVersion(fromGitHubTag: "v1.2.3+4") == nil)
        #expect(AppUpdatePolicy.stableReleaseVersion(fromGitHubTag: " v1.2.3 ") == nil)
    }

    @Test("按 SemVer 顺序比较正式版与预发布版")
    func comparesSemanticVersions() throws {
        let alpha = try #require(AppVersion("1.0.0-alpha"))
        let alphaOne = try #require(AppVersion("1.0.0-alpha.1"))
        let beta = try #require(AppVersion("1.0.0-beta"))
        let release = try #require(AppVersion("1.0.0"))
        let patch = try #require(AppVersion("1.0.1"))
        let minor = try #require(AppVersion("1.1.0"))
        let major = try #require(AppVersion("2.0.0"))
        let patchNine = try #require(AppVersion("2.0.9"))
        let patchTen = try #require(AppVersion("2.0.10"))

        #expect(alpha < alphaOne)
        #expect(alphaOne < beta)
        #expect(beta < release)
        #expect(release < patch)
        #expect(patch < minor)
        #expect(minor < major)
        #expect(patchNine < patchTen)
        #expect(AppVersion("1.0.0+one") == AppVersion("1.0.0+two"))
    }

    @Test("自动检查以二十四小时为边界且不会被时钟回拨永久阻塞")
    func throttlesAutomaticChecks() {
        let now = Date(timeIntervalSince1970: 2_000_000)

        #expect(AppUpdatePolicy.shouldPerformAutomaticCheck(lastCheckedAt: nil, now: now))
        #expect(!AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: now.addingTimeInterval(-86_399),
            now: now
        ))
        #expect(AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: now.addingTimeInterval(-86_400),
            now: now
        ))
        #expect(AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: now.addingTimeInterval(60),
            now: now
        ))
        #expect(!AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: now.addingTimeInterval(-899),
            now: now,
            minimumInterval: AppUpdatePolicy.failedCheckRetryInterval
        ))
        #expect(AppUpdatePolicy.shouldPerformAutomaticCheck(
            lastCheckedAt: now.addingTimeInterval(-900),
            now: now,
            minimumInterval: AppUpdatePolicy.failedCheckRetryInterval
        ))
    }

    @Test("同一新版只自动提醒一次，后续更高版本仍会提醒")
    func notifiesOncePerNewVersion() throws {
        let current = try #require(AppVersion("0.1.4"))
        let latest = try #require(AppVersion("0.1.5"))
        let newer = try #require(AppVersion("0.2.0"))

        #expect(AppUpdatePolicy.shouldNotify(
            currentVersion: current,
            latestVersion: latest,
            lastNotifiedVersion: nil
        ))
        #expect(!AppUpdatePolicy.shouldNotify(
            currentVersion: current,
            latestVersion: latest,
            lastNotifiedVersion: latest
        ))
        #expect(!AppUpdatePolicy.shouldNotify(
            currentVersion: current,
            latestVersion: latest,
            lastNotifiedVersion: newer
        ))
        #expect(AppUpdatePolicy.shouldNotify(
            currentVersion: current,
            latestVersion: newer,
            lastNotifiedVersion: latest
        ))
        #expect(!AppUpdatePolicy.shouldNotify(
            currentVersion: latest,
            latestVersion: latest,
            lastNotifiedVersion: nil
        ))
    }
}

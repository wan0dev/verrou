import AppKit
import Observation

/// Audit additions: expired cards, old passwords, two-factor authentication
/// available (bundled 2fa.directory list) and possible passkeys (bundled
/// passkeys.2fa.directory list). Local, no network.
@MainActor
@Observable
final class Watchtower {
    /// Cards and old passwords (local, without network).
    private(set) var report: WatchtowerReport?
    /// `nil`: not loaded yet (or unavailable, see `twoFactorError`).
    private(set) var twoFactor: TwoFactorReport?
    private(set) var twoFactorError: String?
    /// "Passkey available": `nil` as long as the directory is not loaded (or
    /// if it is unavailable, see `passkeysError`).
    private(set) var passkeys: PasskeyReport?
    private(set) var passkeysError: String?
    /// Item whose passkey creation page is being looked up
    /// (`AppModel.createPasskey`).
    var creatingPasskey: String?
    /// Visual review: audit section to show at the top (`passkeys`).
    var focus: String?

    /// Issues counted in the sidebar.
    var issues: Int {
        (report.map { $0.cards.count + $0.old.count } ?? 0) + (twoFactor?.missing.count ?? 0)
    }

    func refresh(_ session: VaultSession) {
        report = try? session.watchtower()
        loadPasskeys(session)
        loadTwoFactor(session)
    }

    /// "Passkey available", from the bundled directory.
    func loadPasskeys(_ session: VaultSession) {
        do {
            passkeys = try session.passkeyAudit()
            passkeysError = nil
        } catch {
            passkeys = nil
            passkeysError = AppModel.describe(error)
        }
    }

    /// Two-factor authentication available, from the bundled list.
    private func loadTwoFactor(_ session: VaultSession) {
        do {
            twoFactor = try session.twoFactorAudit()
            twoFactorError = nil
        } catch {
            twoFactor = nil
            twoFactorError = AppModel.describe(error)
        }
    }

    func reset() {
        report = nil
        twoFactor = nil
        twoFactorError = nil
        passkeys = nil
        passkeysError = nil
        creatingPasskey = nil
    }
}

// MARK: Change the password

extension ItemSummary {
    /// Login with a site, not in the trash: "Change Password" has a page to
    /// open.
    var canChangePassword: Bool {
        category == .login && host != nil && state != .trashed
    }
}

extension AppModel {
    /// Opens the page where the item's password is changed: page known in
    /// advance (big sites), otherwise the site's home page. The extension
    /// then suggests a strong password, then its update in the vault; at the
    /// next sync, the item leaves the audit.
    func changePassword(of summary: ItemSummary) async {
        guard summary.canChangePassword, changingPassword == nil, lockState == .unlocked else { return }
        changingPassword = summary.id
        defer { changingPassword = nil }
        let hint = String(localized: "Verrou will suggest a strong password and saving it")
        do {
            let page = try session.changePasswordPage(id: summary.id)
            guard lockState == .unlocked, let url = URL(string: page.url) else { return }
            NSWorkspace.shared.open(url)
            switch page.source {
            case .known:
                toast = Toast(message: String(localized: "Change-password page opened"), detail: hint, seconds: 5)
            case .home:
                toast = Toast(message: String(localized: "This site doesn't state its change-password page: opening the home page"),
                              detail: hint, seconds: 6)
            }
        } catch {
            toast = Toast(message: String(localized: "Page not found"), detail: Self.describe(error), failure: true)
        }
    }
}

// MARK: Create a passkey

extension AppModel {
    /// Opens the page where a passkey is created for the item: a page known
    /// in advance, otherwise the directory's address or the site's home
    /// page. In Brave or Firefox, the extension then offers to save the
    /// passkey in the item; at the next sync, it leaves "Passkey available".
    func createPasskey(for candidate: PasskeyCandidate) async {
        let summary = candidate.item
        guard watchtower.creatingPasskey == nil, lockState == .unlocked else { return }
        watchtower.creatingPasskey = summary.id
        defer { watchtower.creatingPasskey = nil }
        let hint = String(localized: "Create it on the site: the Verrou extension for Brave or Firefox will offer to save it in “\(summary.title)”.")
        do {
            let page = try session.passkeySetupPage(id: summary.id)
            guard lockState == .unlocked, let url = URL(string: page.url) else { return }
            NSWorkspace.shared.open(url)
            switch page.source {
            case .known:
                toast = Toast(message: String(localized: "Passkeys page opened"), detail: hint, seconds: 6)
            case .home:
                toast = Toast(message: String(localized: "This site doesn't state its passkeys page: opening the home page"),
                              detail: String(localized: "Look for “passkey” in the account's security settings. ")
                                  + hint, seconds: 8)
            }
        } catch {
            toast = Toast(message: String(localized: "Page not found"), detail: Self.describe(error), failure: true)
        }
    }
}

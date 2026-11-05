//! Audit extras for the app: two-factor authentication available but
//! missing (2fa.directory), expired cards, old passwords, and the logins
//! whose site accepts passkeys. See `verrou_core::watchtower`.
//!
//! The directories are bundled with the app (`verrou_core`'s
//! `TWO_FACTOR_DIRECTORY` and `PASSKEY_DIRECTORY`, refreshed by
//! `scripts/update-directories.sh`): no network.

use std::sync::{Arc, OnceLock};

use verrou_core::passkey_upgrade::{PASSKEY_DIRECTORY, PasskeyDirectory, passkey_candidates};
use verrou_core::watchtower;
use verrou_vaultwarden::change_password::{self, Source};
use verrou_vaultwarden::passkey_setup;
use verrou_vaultwarden::{Connection, Decrypted};

use crate::{ItemSummary, VaultSession, VerrouError, summary};

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// Cards and old passwords: computed locally, no network.
#[derive(Clone, Debug, uniffi::Record)]
pub struct WatchtowerReport {
    /// Cards expired or expiring within 60 days, most urgent first.
    pub cards: Vec<ExpiringCard>,
    /// Logins unchanged for more than 3 years, oldest first.
    pub old: Vec<OldPassword>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ExpiringCard {
    pub item: ItemSummary,
    /// Expiry month and year (`09/2029`).
    pub expiry: String,
    /// Days left until the end of the expiry month; negative: expired.
    pub days_left: i64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct OldPassword {
    pub item: ItemSummary,
    /// Days since the item was last modified.
    pub days: i64,
}

/// Logins whose site offers two-factor authentication, with no one-time
/// code in Verrou.
#[derive(Clone, Debug, uniffi::Record)]
pub struct TwoFactorReport {
    pub missing: Vec<MissingTwoFactor>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct MissingTwoFactor {
    pub item: ItemSummary,
    /// Site name in 2fa.directory.
    pub site: String,
    /// The site accepts one-time codes (TOTP), which Verrou can store and
    /// fill.
    pub totp: bool,
    /// Methods offered (`totp`, `sms`, `u2f`, `email`…).
    pub methods: Vec<String>,
    /// The site's help page for turning it on (HTTPS).
    pub documentation: Option<String>,
}

/// Logins whose site accepts passkeys, with no passkey in Verrou
/// ("Passkey possible").
#[derive(Clone, Debug, uniffi::Record)]
pub struct PasskeyReport {
    pub candidates: Vec<PasskeyCandidate>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct PasskeyCandidate {
    pub item: ItemSummary,
    /// Site domain in the directory (passkeys.2fa.directory).
    pub domain: String,
    /// The passkey can replace the password at sign-in; otherwise it is a
    /// second factor, after the password.
    pub passwordless: bool,
    /// The site requires the passkey (rare).
    pub required: bool,
    /// The site's help page about passkeys (HTTPS).
    pub documentation: Option<String>,
    /// Note from the directory, in English.
    pub notes: Option<String>,
}

/// Where the page offered by "Create a passkey" comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum PasskeySetupSource {
    /// Major site known in advance, no request.
    Known,
    /// The site doesn't give its page: its home page (or the directory's
    /// address).
    Home,
}

impl From<passkey_setup::Source> for PasskeySetupSource {
    fn from(source: passkey_setup::Source) -> Self {
        match source {
            passkey_setup::Source::Known => Self::Known,
            passkey_setup::Source::Home => Self::Home,
        }
    }
}

/// Page to open to create a passkey (HTTPS).
#[derive(Clone, Debug, uniffi::Record)]
pub struct PasskeySetupPage {
    pub url: String,
    pub source: PasskeySetupSource,
}

/// Where the page offered by "Change password" comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum ChangePasswordSource {
    /// Major site known in advance (Google, GitHub…), no request.
    Known,
    /// The site doesn't give its page (or doesn't answer): its home page.
    Home,
}

impl From<Source> for ChangePasswordSource {
    fn from(source: Source) -> Self {
        match source {
            Source::Known => Self::Known,
            Source::Home => Self::Home,
        }
    }
}

/// Page to open to change a login's password (HTTPS).
#[derive(Clone, Debug, uniffi::Record)]
pub struct ChangePasswordPage {
    pub url: String,
    pub source: ChangePasswordSource,
}

/// The bundled 2fa.directory list, parsed once.
fn two_factor_directory() -> Result<&'static watchtower::TwoFactorDirectory, VerrouError> {
    static DIRECTORY: OnceLock<Result<watchtower::TwoFactorDirectory, String>> = OnceLock::new();
    DIRECTORY
        .get_or_init(|| {
            watchtower::TwoFactorDirectory::parse(watchtower::TWO_FACTOR_DIRECTORY)
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|message| VerrouError::Invalid {
            message: message.clone(),
        })
}

/// The bundled passkeys.2fa.directory list, parsed once.
fn passkey_directory() -> Result<&'static PasskeyDirectory, VerrouError> {
    static DIRECTORY: OnceLock<Result<PasskeyDirectory, String>> = OnceLock::new();
    DIRECTORY
        .get_or_init(|| {
            PasskeyDirectory::parse(PASSKEY_DIRECTORY).map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|message| VerrouError::Invalid {
            message: message.clone(),
        })
}

impl VaultSession {
    /// Installs the vault returned by a write made from Verrou (editor,
    /// extension, import).
    pub(crate) fn install_written(
        &self,
        connection: &Arc<tokio::sync::Mutex<Connection>>,
        decrypted: Decrypted,
    ) -> Result<(), VerrouError> {
        self.install_if_current(connection, decrypted)
    }
}

#[uniffi::export]
impl VaultSession {
    /// Expired or soon-to-expire cards, old passwords.
    pub fn watchtower(&self) -> Result<WatchtowerReport, VerrouError> {
        let now = now();
        self.with_vault(|v| {
            Ok(WatchtowerReport {
                cards: watchtower::expiring_cards(v, now)
                    .into_iter()
                    .filter_map(|c| {
                        v.get(&c.id).map(|i| ExpiringCard {
                            item: summary(i),
                            expiry: format!("{:02}/{}", c.expiry.month, c.expiry.year),
                            days_left: c.days_left,
                        })
                    })
                    .collect(),
                old: watchtower::old_passwords(v, now)
                    .into_iter()
                    .filter_map(|(id, days)| {
                        v.get(&id).map(|i| OldPassword {
                            item: summary(i),
                            days,
                        })
                    })
                    .collect(),
            })
        })
    }

    /// Sites of logins that offer two-factor authentication while the item
    /// has no one-time code, from the bundled 2fa.directory list. Local,
    /// no network.
    pub fn two_factor_audit(&self) -> Result<TwoFactorReport, VerrouError> {
        let directory = two_factor_directory()?;
        self.with_vault(|v| {
            Ok(TwoFactorReport {
                missing: watchtower::missing_two_factor(v, directory)
                    .into_iter()
                    .filter_map(|(id, site)| {
                        v.get(&id).map(|i| MissingTwoFactor {
                            item: summary(i),
                            site: site.name.clone(),
                            totp: site.supports_totp(),
                            methods: site.methods.clone(),
                            documentation: site.documentation.clone(),
                        })
                    })
                    .collect(),
            })
        })
    }

    /// Logins whose site accepts passkeys but that don't have one yet
    /// ("Passkey possible"), from the bundled passkeys.2fa.directory
    /// directory. Local, no network.
    pub fn passkey_audit(&self) -> Result<PasskeyReport, VerrouError> {
        let directory = passkey_directory()?;
        self.with_vault(|v| {
            Ok(PasskeyReport {
                candidates: passkey_candidates(v, directory)
                    .into_iter()
                    .filter_map(|(id, site)| {
                        v.get(&id).map(|i| PasskeyCandidate {
                            item: summary(i),
                            domain: site.domain.clone(),
                            passwordless: site.passwordless(),
                            required: site.passwordless == Some(
                                verrou_core::passkey_upgrade::Support::Required,
                            ) || site.mfa == Some(verrou_core::passkey_upgrade::Support::Required),
                            documentation: site.documentation.clone(),
                            notes: site.notes.clone(),
                        })
                    })
                    .collect(),
            })
        })
    }

    /// Page where to create a passkey for a login: a page known in advance,
    /// otherwise the directory's address or the site's home page.
    pub fn passkey_setup_page(&self, id: String) -> Result<PasskeySetupPage, VerrouError> {
        let host = self
            .with_vault(|v| Ok(v.get(&id).ok_or(VerrouError::NotFound)?.primary_host()))?
            .ok_or_else(|| VerrouError::Invalid {
                message: "this item has no site".to_owned(),
            })?;
        // Site address according to the bundled directory.
        let site_url = passkey_directory()?
            .lookup(&host)
            .and_then(|s| s.url.clone());
        let page = passkey_setup::find(&host, site_url.as_deref())?;
        Ok(PasskeySetupPage {
            url: page.url,
            source: page.source.into(),
        })
    }

    /// Page where to change a login's password: major known site, otherwise
    /// the site's home page.
    pub fn change_password_page(&self, id: String) -> Result<ChangePasswordPage, VerrouError> {
        let host = self
            .with_vault(|v| Ok(v.get(&id).ok_or(VerrouError::NotFound)?.primary_host()))?
            .ok_or_else(|| VerrouError::Invalid {
                message: "this item has no site".to_owned(),
            })?;
        let page = change_password::find(&host)?;
        Ok(ChangePasswordPage {
            url: page.url,
            source: page.source.into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn watchtower_reports_mock_cards() {
        let session = VaultSession::new();
        session.unlock_mock(0, 42, crate::MockLanguage::English);
        // The mock vault has cards (09/29, 03/28, 11/27): none expires
        // before autumn 2027.
        let report = session.watchtower().unwrap();
        assert!(report.cards.iter().all(|c| c.days_left <= 60));
    }

    #[test]
    fn passkey_audit_of_the_mock_vault_needs_no_network() {
        let session = VaultSession::new();
        session.unlock_mock(0, 42, crate::MockLanguage::English);
        let report = session.passkey_audit().unwrap();
        let domains: Vec<&str> = report.candidates.iter().map(|c| c.domain.as_str()).collect();
        assert!(domains.contains(&"github.com"), "{domains:?}");
        // Google already has a passkey in the mock vault: nothing to offer
        // (subdomain matching is tested in the core).
        assert!(!report.candidates.iter().any(|c| c.item.title == "Google"));
        // Sorted by title.
        let titles: Vec<String> = report
            .candidates
            .iter()
            .map(|c| c.item.title.to_lowercase())
            .collect();
        let mut sorted = titles.clone();
        sorted.sort();
        assert_eq!(titles, sorted);
        session.lock();
        assert!(matches!(session.passkey_audit(), Err(VerrouError::Locked)));
    }

    #[test]
    fn two_factor_audit_of_the_mock_vault_needs_no_account() {
        let session = VaultSession::new();
        session.unlock_mock(0, 42, crate::MockLanguage::English);
        // The bundled directory is enough: the audit works on the mock
        // vault too.
        assert!(!session.two_factor_audit().unwrap().missing.is_empty());
        session.lock();
        assert!(matches!(
            session.two_factor_audit(),
            Err(VerrouError::Locked)
        ));
    }

    #[test]
    fn change_password_page_needs_a_site() {
        let session = VaultSession::new();
        session.unlock_mock(0, 42, crate::MockLanguage::English);
        assert!(matches!(
            session.change_password_page("absent".to_owned()),
            Err(VerrouError::NotFound)
        ));
    }
}

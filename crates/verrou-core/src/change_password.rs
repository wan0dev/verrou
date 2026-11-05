//! A site's change-password page.
//!
//! This module makes no request. A few big sites have a stable settings
//! page: a short table (`KNOWN`) serves them directly. The page is looked
//! up in `verrou_vaultwarden::change_password`, which falls back to the
//! site's home page.

use crate::matching::{host_of, registrable_domain};

/// Domains covered by a `KNOWN` entry.
enum Domains {
    /// Exact registrable domains (`live.com`, `x.com`…).
    Exact(&'static [&'static str]),
    /// A name under any public suffix (`amazon`: `amazon.fr`,
    /// `amazon.co.uk`…).
    AnySuffix(&'static str),
}

/// Big sites and their change page (or account security page).
/// `{domain}`: the item's registrable
/// domain (`amazon.fr` stays on `amazon.fr`). Short list, kept up to date
/// by hand: an address that changes simply stops being the right page,
/// the site then redirects to its home page.
const KNOWN: &[(Domains, &str)] = &[
    (
        Domains::AnySuffix("google"),
        "https://myaccount.google.com/signinoptions/password",
    ),
    (
        Domains::Exact(&["youtube.com", "gmail.com"]),
        "https://myaccount.google.com/signinoptions/password",
    ),
    (
        Domains::Exact(&["github.com"]),
        "https://github.com/settings/security",
    ),
    // "Your account", where "Login & security" starts from.
    (
        Domains::AnySuffix("amazon"),
        "https://www.{domain}/gp/css/homepage.html",
    ),
    (
        Domains::Exact(&[
            "microsoft.com",
            "live.com",
            "outlook.com",
            "hotmail.com",
            "xbox.com",
            "office.com",
        ]),
        "https://account.live.com/password/change",
    ),
    (
        Domains::Exact(&["apple.com", "icloud.com"]),
        "https://account.apple.com/account/manage",
    ),
    (
        Domains::Exact(&["facebook.com"]),
        "https://accountscenter.facebook.com/password_and_security",
    ),
    (
        Domains::Exact(&["twitter.com", "x.com"]),
        "https://x.com/settings/password",
    ),
    (
        Domains::Exact(&["linkedin.com"]),
        "https://www.linkedin.com/mypreferences/d/change-password",
    ),
    (
        Domains::Exact(&["dropbox.com"]),
        "https://www.dropbox.com/account/security",
    ),
];

/// Page known in advance for an item's host (`KNOWN` table), from its
/// registrable domain: `accounts.google.com` as well as `google.fr`.
pub fn known_url(host: &str) -> Option<String> {
    let domain = registrable_domain(host)?;
    let (name, _) = domain.split_once('.')?;
    KNOWN.iter().find_map(|(domains, url)| {
        let hit = match domains {
            Domains::Exact(list) => list.contains(&domain.as_str()),
            Domains::AnySuffix(wanted) => name == *wanted,
        };
        hit.then(|| url.replace("{domain}", &domain))
    })
}

/// Hosts to try, in order: the item's as stored (`login.exemple.fr`),
/// then its registrable domain (`exemple.fr`) if different. Nothing for
/// an app address or an empty input.
pub fn candidate_hosts(input: &str) -> Vec<String> {
    let Some(host) = host_of(input) else {
        return Vec::new();
    };
    let mut hosts = vec![host.clone()];
    if let Some(domain) = registrable_domain(&host)
        && domain != host
    {
        hosts.push(domain);
    }
    hosts
}

/// HTTPS origin of a host (`https://exemple.fr`): the home page, for want
/// of anything better.
pub fn origin(host: &str) -> String {
    format!("https://{host}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_are_the_host_then_its_registrable_domain() {
        assert_eq!(
            candidate_hosts("https://login.exemple.co.uk/session?x=1"),
            ["login.exemple.co.uk", "exemple.co.uk"]
        );
        // `www.` is already stripped by `host_of`: a single candidate.
        assert_eq!(candidate_hosts("https://www.exemple.fr"), ["exemple.fr"]);
        assert_eq!(candidate_hosts("exemple.fr"), ["exemple.fr"]);
        // IP address, local name: the host alone.
        assert_eq!(candidate_hosts("http://192.168.1.1:8080"), ["192.168.1.1"]);
        assert_eq!(candidate_hosts("routeur"), ["routeur"]);
        // An app is not a site.
        assert_eq!(
            candidate_hosts("macapp://com.exemple.app"),
            Vec::<String>::new()
        );
        assert_eq!(candidate_hosts("  "), Vec::<String>::new());
    }

    #[test]
    fn known_sites_open_directly() {
        assert_eq!(
            known_url("accounts.google.com").as_deref(),
            Some("https://myaccount.google.com/signinoptions/password")
        );
        assert_eq!(
            known_url("google.fr").as_deref(),
            Some("https://myaccount.google.com/signinoptions/password")
        );
        assert_eq!(
            known_url("github.com").as_deref(),
            Some("https://github.com/settings/security")
        );
        assert_eq!(
            known_url("login.live.com").as_deref(),
            Some("https://account.live.com/password/change")
        );
        assert_eq!(
            known_url("twitter.com"),
            known_url("x.com"),
            "Twitter and X: same page"
        );
        // Amazon stays on the item's domain.
        assert_eq!(
            known_url("amazon.fr").as_deref(),
            Some("https://www.amazon.fr/gp/css/homepage.html")
        );
        assert_eq!(
            known_url("www.amazon.co.uk").as_deref(),
            Some("https://www.amazon.co.uk/gp/css/homepage.html")
        );
    }

    #[test]
    fn unknown_sites_and_lookalikes_are_not_matched() {
        assert_eq!(known_url("exemple.fr"), None);
        // The name must be exactly the registrable domain.
        assert_eq!(known_url("github.io"), None);
        assert_eq!(known_url("mygithub.com"), None);
        assert_eq!(known_url("github.com.evil.fr"), None);
        assert_eq!(known_url("google.evil.fr"), None);
        assert_eq!(known_url("notamazon.fr"), None);
        assert_eq!(known_url("macapp://com.google.app"), None);
    }

    #[test]
    fn every_known_url_is_https() {
        for (_, url) in KNOWN {
            assert!(url.starts_with("https://"), "{url}");
        }
    }
}

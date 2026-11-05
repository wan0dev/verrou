//! "Create a passkey": find the page where to do it on a site.
//!
//! A page known in advance for a few big sites
//! (`verrou_core::passkey_upgrade::known_setup_url`); then the site address
//! given by the bundled directory; failing that, the site's home page. No
//! request is made to the site.

use verrou_core::change_password::{candidate_hosts, origin};
use verrou_core::passkey_upgrade::known_setup_url;

use crate::Error;

/// Where the proposed address comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// Table of big sites, without request.
    Known,
    /// The site doesn't give its page: the directory's address, or its home page.
    Home,
}

/// Page to open to create a passkey.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page {
    pub url: String,
    pub source: Source,
}

/// The passkey creation page for a login's host (or address). `site_url`:
/// the site's address according to the directory, if it gives one. An
/// error only if there is no site.
pub fn find(site: &str, site_url: Option<&str>) -> Result<Page, Error> {
    let hosts = candidate_hosts(site);
    let Some(host) = hosts.first() else {
        return Err(Error::Invalid("this item has no site".to_owned()));
    };
    if let Some(url) = known_setup_url(host) {
        return Ok(Page {
            url,
            source: Source::Known,
        });
    }
    let home = site_url
        .filter(|u| u.starts_with("https://"))
        .map_or_else(|| origin(host), str::to_owned);
    Ok(Page {
        url: home,
        source: Source::Home,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_sites_need_no_request() {
        // No request: the table is enough (the test passes offline).
        let page = find("https://github.com/login", None).unwrap();
        assert_eq!(page.source, Source::Known);
        assert_eq!(page.url, "https://github.com/settings/security");
        assert!(matches!(
            find("macapp://com.exemple", None),
            Err(Error::Invalid(_))
        ));
    }

    #[test]
    fn the_directory_address_comes_before_the_home_page() {
        // A site outside the known table, whose address is not its domain.
        let page = find(
            "https://drs.ct.gov/eservices/login",
            Some("https://drs.ct.gov/eservices/"),
        )
        .unwrap();
        assert_eq!(
            page,
            Page {
                url: "https://drs.ct.gov/eservices/".to_owned(),
                source: Source::Home,
            }
        );
        // Without the directory's address: the site's home page.
        let page =
            find("https://boutique.exemple.fr/connexion", Some("http://pas-https")).unwrap();
        assert_eq!(page.url, "https://boutique.exemple.fr");
    }
}

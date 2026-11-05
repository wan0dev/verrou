//! "Change password": find the page where to do it on a site.
//!
//! A page known in advance for a few big sites
//! (`verrou_core::change_password::known_url`, without request), and
//! failing that the site's home page. No request is made to the site.

use verrou_core::change_password::{candidate_hosts, known_url, origin};

use crate::Error;

/// Where the proposed address comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// Table of big sites, without request.
    Known,
    /// The site doesn't give its page: its home page.
    Home,
}

/// Page to open to change the password.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Page {
    pub url: String,
    pub source: Source,
}

/// The password change page for a login's host (or address). An error only
/// if there is no site.
pub fn find(site: &str) -> Result<Page, Error> {
    let hosts = candidate_hosts(site);
    let Some(host) = hosts.first() else {
        return Err(Error::Invalid("this item has no site".to_owned()));
    };
    if let Some(url) = known_url(host) {
        return Ok(Page {
            url,
            source: Source::Known,
        });
    }
    Ok(Page {
        url: origin(host),
        source: Source::Home,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_sites_need_no_request() {
        // No request: the table is enough (the test passes offline).
        let page = find("https://accounts.google.com/signin").unwrap();
        assert_eq!(page.source, Source::Known);
        assert!(page.url.starts_with("https://myaccount.google.com/"));
        assert!(matches!(find("macapp://com.exemple"), Err(Error::Invalid(_))));
    }

    #[test]
    fn other_sites_open_their_home_page() {
        let page = find("https://boutique.exemple.fr/connexion").unwrap();
        assert_eq!(
            page,
            Page {
                url: "https://boutique.exemple.fr".to_owned(),
                source: Source::Home,
            }
        );
    }
}

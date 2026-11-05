//! JSON parsed from data Verrou doesn't control: the bundled 2fa.directory
//! list (and its refreshes, downloaded by scripts/update-directories.sh).
#![no_main]

use libfuzzer_sys::fuzz_target;
use verrou_core::watchtower::TwoFactorDirectory;

fuzz_target!(|data: &[u8]| {
    let _ = TwoFactorDirectory::parse(data);
});

use std::fmt;
use std::fs;

use anyhow::{Context, Result};

use crate::bootspec::Bootspec;
use crate::profile::Profile;

/// A generation is the actual derivation to which a profile points.
///
/// This derivation contains almost all information necessary to be installed
/// onto the EFI system partition. The only information missing is the version
/// number which it retrives from the profile.
#[derive(Debug)]
pub struct Generation {
    version: u64,
    specialisation_name: Option<String>,
    pub bootspec: Bootspec,
}

impl Generation {
    pub fn from_profile(profile: &Profile) -> Result<Self> {
        let bootspec_path = profile.path.join("bootspec/boot.v1.json");
        let bootspec: Bootspec = serde_json::from_slice(
            &fs::read(bootspec_path).context("Failed to read bootspec file")?,
        )
        .context("Failed to parse bootspec json")?;

        Ok(Self {
            version: profile.version,
            specialisation_name: None,
            bootspec,
        })
    }

    pub fn specialise(&self, name: &str, bootspec: &Bootspec) -> Self {
        Self {
            version: self.version,
            specialisation_name: Some(String::from(name)),
            bootspec: bootspec.clone(),
        }
    }

    pub fn is_specialized(&self) -> Option<String> {
        self.specialisation_name.clone()
    }
}

impl fmt::Display for Generation {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.version)
    }
}

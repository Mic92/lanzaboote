use std::cmp::Ordering;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

/// A profile is a symlink to a generation. It encodes the version of
/// the generation it points to in its file name.
#[derive(Debug)]
pub struct Profile {
    pub version: u64,
    pub path: PathBuf,
}

impl Profile {
    pub fn from_path(path: impl AsRef<Path>) -> Result<Self> {
        Ok(Self {
            version: parse_version(&path).context("Failed to parse version")?,
            path: PathBuf::from(path.as_ref()),
        })
    }
}

impl PartialEq for Profile {
    fn eq(&self, other: &Self) -> bool {
        self.version == other.version
    }
}

impl Eq for Profile {}

impl PartialOrd for Profile {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        self.version.partial_cmp(&other.version)
    }
}

impl Ord for Profile {
    fn cmp(&self, other: &Self) -> Ordering {
        self.version.cmp(&other.version)
    }
}

fn parse_version(path: impl AsRef<Path>) -> Result<u64> {
    let file_name = path.as_ref().file_name().ok_or_else(|| {
        anyhow::anyhow!(
            "Failed to extract file name from profile path: {:?}",
            path.as_ref()
        )
    })?;

    let file_name_str = file_name
        .to_str()
        .with_context(|| "Failed to convert file name of profile to string")?;

    let generation_version_str = file_name_str.split('-').nth(1).ok_or_else(|| {
        anyhow::anyhow!("Failed to extract version from profile: {}", file_name_str)
    })?;

    let generation_version = generation_version_str.parse().with_context(|| {
        format!(
            "Failed to parse generation version: {}",
            generation_version_str
        )
    })?;

    Ok(generation_version)
}

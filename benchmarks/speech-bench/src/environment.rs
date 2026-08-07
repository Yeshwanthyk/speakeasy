use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EnvironmentFingerprint {
    pub repository_commit: Option<String>,
    pub repository_dirty: bool,
    pub repository_dirty_hash: Option<String>,
    pub operating_system: String,
    pub architecture: String,
    pub hardware_model: Option<String>,
    pub logical_cpu_count: usize,
    pub memory_bytes: Option<u64>,
    pub rustc_version: Option<String>,
    pub production_lock_sha256: Option<String>,
    pub benchmark_lock_sha256: Option<String>,
}

impl EnvironmentFingerprint {
    pub fn collect(repo_root: &Path, benchmark_root: &Path) -> Self {
        let status = git_output(repo_root, &["status", "--porcelain=v1", "-z"]);
        let diff = git_output(repo_root, &["diff", "--binary", "HEAD"]);
        let dirty = status.as_ref().is_some_and(|value| !value.is_empty());
        let dirty_hash = if dirty {
            let mut hasher = Sha256::new();
            if let Some(value) = status {
                hasher.update(value.as_bytes());
            }
            if let Some(value) = diff {
                hasher.update(value.as_bytes());
            }
            Some(hex::encode(hasher.finalize()))
        } else {
            None
        };

        Self {
            repository_commit: git_output(repo_root, &["rev-parse", "HEAD"]),
            repository_dirty: dirty,
            repository_dirty_hash: dirty_hash,
            operating_system: format!("{} {}", std::env::consts::OS, os_version()),
            architecture: std::env::consts::ARCH.into(),
            hardware_model: command_output("sysctl", &["-n", "hw.model"]),
            logical_cpu_count: std::thread::available_parallelism()
                .map(usize::from)
                .unwrap_or(1),
            memory_bytes: command_output("sysctl", &["-n", "hw.memsize"])
                .and_then(|value| value.parse().ok()),
            rustc_version: command_output("rustc", &["--version"]),
            production_lock_sha256: hash_optional_file(
                &repo_root.join("rust/asr_bridge/Cargo.lock"),
            ),
            benchmark_lock_sha256: hash_optional_file(&benchmark_root.join("Cargo.lock")),
        }
    }
}

pub fn discover_repo_root(start: &Path) -> Result<PathBuf, String> {
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(start)
        .output()
        .map_err(|error| format!("failed to launch git: {error}"))?;
    if !output.status.success() {
        return Err("current directory is not inside a Git repository".into());
    }
    let value = String::from_utf8(output.stdout)
        .map_err(|error| format!("git returned non-UTF-8 repository path: {error}"))?;
    Ok(PathBuf::from(value.trim()))
}

pub fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = File::open(path)
        .map_err(|error| format!("failed to open {} for hashing: {error}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 1024 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("failed to read {} for hashing: {error}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(hex::encode(hasher.finalize()))
}

fn hash_optional_file(path: &Path) -> Option<String> {
    sha256_file(path).ok()
}

fn git_output(repo_root: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn os_version() -> String {
    command_output("sw_vers", &["-productVersion"])
        .or_else(|| command_output("uname", &["-r"]))
        .unwrap_or_else(|| "unknown".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_file_matches_known_digest() {
        let directory = tempfile::tempdir().expect("temporary directory");
        let path = directory.path().join("fixture");
        std::fs::write(&path, b"abc").expect("write fixture");

        assert_eq!(
            sha256_file(&path).unwrap(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}

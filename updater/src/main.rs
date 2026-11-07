#![cfg_attr(windows, windows_subsystem = "windows")]

mod package;
mod parent;
mod transaction;

use package::{Manifest, hash_file, validate_tree};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
const MANIFEST: &str = "PoFig-update.json";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PrepareJob {
    archive: PathBuf,
    destination: PathBuf,
    sha256: String,
    version: String,
    platform: String,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct InstallJob {
    id: String,
    target: PathBuf,
    stage: PathBuf,
    manifest: PathBuf,
    manifest_sha256: String,
    backup: PathBuf,
    parent_pid: u32,
    version: String,
    platform: String,
    #[serde(default = "yes")]
    restart: bool,
}
fn yes() -> bool {
    true
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let mut data = Vec::new();
    fs::File::open(path)?
        .take(4 * 1024 * 1024 + 1)
        .read_to_end(&mut data)?;
    if data.len() > 4 * 1024 * 1024 {
        return Err("update record too large".into());
    }
    Ok(serde_json::from_slice(&data)?)
}
fn platform() -> &'static str {
    if cfg!(windows) { "windows" } else { "macos" }
}
fn event(value: serde_json::Value) {
    let _ = writeln!(io::stdout(), "{value}");
    let _ = io::stdout().flush();
}
fn valid_version(v: &str) -> bool {
    let parts: Vec<_> = v.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|p| {
            !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) && p.parse::<u32>().is_ok()
        })
}
fn prepare(path: &Path) -> Result<()> {
    let job: PrepareJob = read_json(path)?;
    if job.platform != platform() || !valid_version(&job.version) {
        return Err("wrong platform or version".into());
    }
    if fs::metadata(&job.archive)?.len() > 300 * 1024 * 1024 {
        return Err("archive too large".into());
    }
    if hash_file(&job.archive)? != job.sha256 {
        return Err("download checksum mismatch".into());
    }
    package::extract(&job.archive, &job.destination)?;
    let manifest_path = job.destination.join(MANIFEST);
    let manifest: Manifest = read_json(&manifest_path)?;
    let root = if cfg!(windows) {
        job.destination.clone()
    } else {
        job.destination.join("PoFig.app")
    };
    manifest.check(&job.platform, &job.version)?;
    validate_tree(&root, &manifest, cfg!(windows))?;
    event(
        serde_json::json!({"event":"prepared","root":root,"manifest":manifest_path,"manifest_sha256":hash_file(&manifest_path)?}),
    );
    Ok(())
}
fn validate_install(job: &InstallJob, workspace: &Path, verify_stage: bool) -> Result<Manifest> {
    if job.platform != platform()
        || !valid_version(&job.version)
        || job.id.len() != 36
        || !job.id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
        || !job.target.is_absolute()
        || !job.stage.is_absolute()
        || !job.backup.is_absolute()
        || job.target == job.stage
        || job.target.starts_with(&job.stage)
        || job.stage.starts_with(&job.target)
        || package::is_redirect(&job.target)?
    {
        return Err("invalid installation paths".into());
    }
    let expected_backup = if cfg!(windows) {
        workspace.join("backup")
    } else {
        job.target
            .parent()
            .ok_or("missing application parent")?
            .join(format!(".PoFig-backup-{}.app", job.id))
    };
    if job.backup != expected_backup {
        return Err("invalid backup path".into());
    }
    if cfg!(windows) {
        if !job.target.join("PoFig.exe").is_file() {
            return Err("not a PoFig folder".into());
        }
    } else {
        if job.target.extension().and_then(|v| v.to_str()) != Some("app")
            || !job.target.join("Contents/MacOS/PoFig").is_file()
            || job.stage.parent() != job.target.parent()
            || job.stage.file_name().and_then(|v| v.to_str())
                != Some(&format!(".PoFig-update-{}.app", job.id))
        {
            return Err("not a PoFig bundle".into());
        }
    }
    if hash_file(&job.manifest)? != job.manifest_sha256 {
        return Err("manifest checksum mismatch".into());
    }
    let manifest: Manifest = read_json(&job.manifest)?;
    manifest.check(&job.platform, &job.version)?;
    if verify_stage {
        validate_tree(&job.stage, &manifest, cfg!(windows))?;
    }
    Ok(manifest)
}
fn write_result(workspace: &Path, job: &InstallJob, status: &str, message: &str) -> Result<()> {
    let tmp = workspace.join("result.tmp");
    fs::write(
        &tmp,
        serde_json::to_vec(
            &serde_json::json!({"status":status,"version":job.version,"message":message,"backup":job.backup}),
        )?,
    )?;
    let result = workspace.join("result.json");
    if result.exists() {
        fs::remove_file(&result)?;
    }
    fs::rename(tmp, result)?;
    Ok(())
}
fn launch(job: &InstallJob) -> Result<()> {
    if !job.restart {
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let status = std::process::Command::new("/usr/bin/open")
            .arg("-n")
            .arg(&job.target)
            .status()?;
        if !status.success() {
            return Err("could not reopen PoFig".into());
        }
    }
    #[cfg(windows)]
    {
        std::process::Command::new(job.target.join("PoFig.exe"))
            .current_dir(&job.target)
            .spawn()?;
    }
    Ok(())
}
fn install(path: &Path, recover_pid: Option<u32>) -> Result<()> {
    let workspace = path.parent().ok_or("missing workspace")?;
    let job: InstallJob = read_json(path)?;
    let manifest = validate_install(&job, workspace, recover_pid.is_none())?;
    if let Some(pid) = recover_pid {
        if let Ok(parent) = parent::Parent::open(pid) {
            parent.wait()?;
        }
        transaction::recover(&job, workspace)?;
        write_result(
            workspace,
            &job,
            "failed",
            "Update was interrupted; the previous version was restored.",
        )?;
        launch(&job)?;
        return Ok(());
    }
    transaction::preflight(&job, &manifest, workspace)?;
    let parent = parent::Parent::open(job.parent_pid)?;
    event(serde_json::json!({"event":"ready","pid":std::process::id()}));
    parent.wait()?;
    let result = transaction::apply(&job, &manifest, workspace);
    if let Err(error) = result {
        let recovery = transaction::recover(&job, workspace);
        let message = format!("{error}; rollback: {recovery:?}");
        write_result(workspace, &job, "failed", &message)?;
        let _ = launch(&job);
        return Err(message.into());
    }
    write_result(workspace, &job, "installed", "")?;
    if let Err(error) = launch(&job) {
        transaction::recover(&job, workspace)?;
        write_result(workspace, &job, "failed", &error.to_string())?;
        let _ = launch(&job);
        return Err(error);
    }
    Ok(())
}
fn main() {
    let args: Vec<_> = std::env::args_os().collect();
    let result = (|| -> Result<()> {
        let action = args
            .get(1)
            .and_then(|v| v.to_str())
            .ok_or("missing action")?;
        let path = Path::new(args.get(2).ok_or("missing job")?);
        match action {
            "prepare" if args.len() == 3 => prepare(path),
            "install" if args.len() == 3 => install(path, None),
            "recover" if args.len() == 4 => install(
                path,
                Some(args[3].to_str().ok_or("invalid parent")?.parse()?),
            ),
            _ => Err("invalid updater command".into()),
        }
    })();
    if let Err(error) = result {
        event(serde_json::json!({"event":"error","message":error.to_string()}));
        std::process::exit(1);
    }
}

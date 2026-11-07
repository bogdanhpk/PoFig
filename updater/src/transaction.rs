use crate::package::{Manifest, checked_join, hash_file};
use crate::{InstallJob, MANIFEST, Result, read_json};
#[cfg(target_os = "macos")]
use serde::{Deserialize, Serialize};
use std::{fs, path::Path};

#[cfg(target_os = "macos")]
#[derive(Deserialize, Serialize)]
struct Journal {
    old_probe: String,
}
pub fn preflight(job: &InstallJob, new: &Manifest, workspace: &Path) -> Result<()> {
    if job.backup.exists() {
        return Err("backup already exists".into());
    }
    if cfg!(windows) {
        let old: Manifest = read_json(&job.target.join(MANIFEST))?;
        old.check("windows", &old.version)?;
        for f in &old.files {
            if hash_file(&checked_join(&job.target, &f.path)?)? != f.sha256 {
                return Err(format!("installed file was changed: {}", f.path).into());
            }
        }
        for f in &new.files {
            let path = checked_join(&job.target, &f.path)?;
            if path.exists() && !old.files.iter().any(|v| v.path == f.path) {
                return Err("new update file conflicts with an unrelated file".into());
            }
        }
    } else {
        let probe = job
            .target
            .parent()
            .ok_or("no application folder")?
            .join(format!(".PoFig-access-{}", job.id));
        fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&probe)?;
        fs::remove_file(probe)?;
    }
    fs::create_dir_all(workspace)?;
    Ok(())
}
pub fn apply(job: &InstallJob, new: &Manifest, workspace: &Path) -> Result<()> {
    preflight(job, new, workspace)?;
    #[cfg(target_os = "macos")]
    {
        let probe = hash_file(&job.target.join("Contents/Info.plist"))?;
        fs::write(
            workspace.join("transaction.json"),
            serde_json::to_vec(&Journal { old_probe: probe })?,
        )?;
        swap(&job.target, &job.stage)?;
        fs::rename(&job.stage, &job.backup)?;
    }
    #[cfg(windows)]
    {
        apply_files(&job.target, &job.stage, &job.backup, new, atomic_copy)?;
    }
    let _ = (new, workspace);
    Ok(())
}
pub fn recover(job: &InstallJob, workspace: &Path) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        let path = workspace.join("transaction.json");
        if !path.exists() {
            return Ok(());
        }
        let journal: Journal = read_json(&path)?;
        if hash_file(&job.target.join("Contents/Info.plist"))? != journal.old_probe {
            let old = if job.backup.exists() {
                &job.backup
            } else {
                &job.stage
            };
            if hash_file(&old.join("Contents/Info.plist"))? != journal.old_probe {
                return Err("previous app could not be verified".into());
            }
            swap(&job.target, old)?;
        }
    }
    #[cfg(windows)]
    {
        recover_files(&job.target, &job.backup, &job.manifest)?;
    }
    let _ = workspace;
    Ok(())
}
#[cfg(target_os = "macos")]
fn swap(a: &Path, b: &Path) -> Result<()> {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let a = CString::new(a.as_os_str().as_bytes())?;
    let b = CString::new(b.as_os_str().as_bytes())?;
    if unsafe {
        libc::renameatx_np(
            libc::AT_FDCWD,
            a.as_ptr(),
            libc::AT_FDCWD,
            b.as_ptr(),
            libc::RENAME_SWAP,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}
#[cfg(any(windows, test))]
fn atomic_copy(source: &Path, target: &Path) -> Result<()> {
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent)?;
    }
    let temporary = target.with_file_name(format!(
        ".{}.PoFig-update",
        target
            .file_name()
            .ok_or("missing target name")?
            .to_string_lossy()
    ));
    if temporary.exists() {
        return Err("update temporary file already exists".into());
    }
    if let Err(error) = fs::copy(source, &temporary) {
        let _ = fs::remove_file(&temporary);
        return Err(error.into());
    }
    #[cfg(windows)]
    {
        use std::{ffi::OsStr, os::windows::ffi::OsStrExt};
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn MoveFileExW(from: *const u16, to: *const u16, flags: u32) -> i32;
        }
        fn wide(v: &OsStr) -> Vec<u16> {
            v.encode_wide().chain(Some(0)).collect()
        }
        let a = wide(temporary.as_os_str());
        let b = wide(target.as_os_str());
        if unsafe { MoveFileExW(a.as_ptr(), b.as_ptr(), 0x1 | 0x8) } == 0 {
            let error = std::io::Error::last_os_error();
            let _ = fs::remove_file(&temporary);
            return Err(error.into());
        }
    }
    #[cfg(not(windows))]
    {
        fs::rename(&temporary, target)?;
    }
    Ok(())
}
#[cfg(any(windows, test))]
fn apply_files<F: FnMut(&Path, &Path) -> Result<()>>(
    target: &Path,
    stage: &Path,
    backup: &Path,
    new: &Manifest,
    mut copy: F,
) -> Result<()> {
    let old: Manifest = read_json(&target.join(MANIFEST))?;
    fs::create_dir(backup)?;
    for f in &old.files {
        let from = checked_join(target, &f.path)?;
        let to = checked_join(backup, &f.path)?;
        fs::create_dir_all(to.parent().ok_or("no backup parent")?)?;
        fs::copy(from, to)?;
    }
    fs::copy(target.join(MANIFEST), backup.join(MANIFEST))?;
    let mut files = new.files.clone();
    files.sort_by_key(|f| match f.path.as_str() {
        "PoFig.exe" => 3,
        "PoFig.dll" => 2,
        _ => 0,
    });
    for f in files {
        copy(
            &checked_join(stage, &f.path)?,
            &checked_join(target, &f.path)?,
        )?;
    }
    for f in &old.files {
        if !new.files.iter().any(|v| v.path == f.path) {
            let path = checked_join(target, &f.path)?;
            if crate::package::is_redirect(&path)? {
                return Err("redirected old file".into());
            }
            fs::remove_file(path)?;
        }
    }
    copy(&stage.join(MANIFEST), &target.join(MANIFEST))?;
    Ok(())
}

#[cfg(any(windows, test))]
fn recover_files(target: &Path, backup: &Path, manifest: &Path) -> Result<()> {
    if backup.join(MANIFEST).exists() {
        let old: Manifest = read_json(&backup.join(MANIFEST))?;
        let new: Manifest = read_json(manifest)?;
        for f in &old.files {
            let source = checked_join(backup, &f.path)?;
            if hash_file(&source)? != f.sha256 {
                return Err("backup checksum mismatch".into());
            }
            atomic_copy(&source, &checked_join(target, &f.path)?)?;
        }
        for f in &new.files {
            if !old.files.iter().any(|v| v.path == f.path) {
                let path = checked_join(target, &f.path)?;
                if path.is_file() {
                    fs::remove_file(path)?;
                }
            }
        }
        atomic_copy(&backup.join(MANIFEST), &target.join(MANIFEST))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::package::Entry;
    use std::path::PathBuf;
    struct Fixture(PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn fixture() -> Fixture {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let next = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "pofig-transaction-{next}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&path).unwrap();
        Fixture(path)
    }
    fn package(root: &Path, version: &str, files: &[(&str, &str)]) -> Manifest {
        fs::create_dir(root).unwrap();
        let mut entries = Vec::new();
        for (name, value) in files {
            fs::write(root.join(name), value).unwrap();
            entries.push(Entry {
                path: name.to_string(),
                sha256: hash_file(&root.join(name)).unwrap(),
                mode: 0o644,
            });
        }
        let manifest = Manifest {
            product: "PoFig".into(),
            platform: "windows".into(),
            version: version.into(),
            files: entries,
        };
        fs::write(root.join(MANIFEST), serde_json::to_vec(&manifest).unwrap()).unwrap();
        manifest
    }
    #[test]
    fn windows_update_preserves_unrelated_files_and_removes_obsolete_owned_files() {
        let f = fixture();
        let target = f.0.join("target");
        let stage = f.0.join("stage");
        let backup = f.0.join("backup");
        package(
            &target,
            "0.2.0",
            &[("PoFig.exe", "old"), ("obsolete.dll", "old")],
        );
        let new = package(
            &stage,
            "0.3.0",
            &[("PoFig.exe", "new"), ("added.dll", "new")],
        );
        fs::write(target.join("personal.txt"), "untouched").unwrap();
        apply_files(&target, &stage, &backup, &new, atomic_copy).unwrap();
        assert_eq!(fs::read_to_string(target.join("PoFig.exe")).unwrap(), "new");
        assert!(!target.join("obsolete.dll").exists());
        assert_eq!(
            fs::read_to_string(target.join("personal.txt")).unwrap(),
            "untouched"
        );
        assert_eq!(fs::read_to_string(backup.join("PoFig.exe")).unwrap(), "old");
    }
    #[test]
    fn partial_windows_update_rolls_back_and_recovery_is_repeatable() {
        let f = fixture();
        let target = f.0.join("target");
        let stage = f.0.join("stage");
        let backup = f.0.join("backup");
        package(
            &target,
            "0.2.0",
            &[("PoFig.exe", "old"), ("obsolete.dll", "old")],
        );
        let new = package(
            &stage,
            "0.3.0",
            &[("PoFig.exe", "new"), ("added.dll", "new")],
        );
        fs::write(target.join("personal.txt"), "untouched").unwrap();
        let mut count = 0;
        assert!(
            apply_files(&target, &stage, &backup, &new, |a, b| {
                count += 1;
                if count == 2 {
                    return Err("simulated locked executable".into());
                }
                atomic_copy(a, b)
            })
            .is_err()
        );
        for _ in 0..2 {
            recover_files(&target, &backup, &stage.join(MANIFEST)).unwrap();
        }
        assert_eq!(fs::read_to_string(target.join("PoFig.exe")).unwrap(), "old");
        assert!(!target.join("added.dll").exists());
        assert!(target.join("obsolete.dll").exists());
        assert_eq!(
            fs::read_to_string(target.join("personal.txt")).unwrap(),
            "untouched"
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn mac_bundle_swap_is_atomic_and_restores_previous_bundle() {
        let f = fixture();
        let a = f.0.join("PoFig.app");
        let b = f.0.join("stage.app");
        fs::create_dir(&a).unwrap();
        fs::create_dir(&b).unwrap();
        fs::write(a.join("version"), "old").unwrap();
        fs::write(b.join("version"), "new").unwrap();
        swap(&a, &b).unwrap();
        assert_eq!(fs::read_to_string(a.join("version")).unwrap(), "new");
        swap(&a, &b).unwrap();
        assert_eq!(fs::read_to_string(a.join("version")).unwrap(), "old");
    }
}

use crate::{MANIFEST, Result};
use ring::digest::{Context, SHA256};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
};

#[derive(Deserialize, Serialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub path: String,
    pub sha256: String,
    #[serde(default)]
    pub mode: u32,
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub product: String,
    pub platform: String,
    pub version: String,
    pub files: Vec<Entry>,
}
impl Manifest {
    pub fn check(&self, platform: &str, version: &str) -> Result<()> {
        if self.product != "PoFig"
            || self.platform != platform
            || self.version != version
            || self.files.is_empty()
            || self.files.len() > 10000
        {
            return Err("invalid package manifest".into());
        }
        let mut names = HashSet::new();
        for f in &self.files {
            safe_path(&f.path)?;
            if f.path == MANIFEST
                || f.sha256.len() != 64
                || !f.sha256.bytes().all(|b| b.is_ascii_hexdigit())
                || !names.insert(f.path.to_lowercase())
            {
                return Err("invalid manifest entry".into());
            }
        }
        let executable = if platform == "macos" {
            "Contents/MacOS/PoFig"
        } else {
            "PoFig.exe"
        };
        if !self.files.iter().any(|f| f.path == executable) {
            return Err("missing PoFig executable".into());
        }
        Ok(())
    }
}
pub fn hash_file(path: &Path) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut hash = Context::new(&SHA256);
    let mut buffer = [0u8; 65536];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hash
        .finish()
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}
pub fn safe_path(value: &str) -> Result<PathBuf> {
    if value.is_empty() || value.len() > 1024 || value.contains('\\') || !value.is_ascii() {
        return Err("unsafe update path".into());
    }
    let mut path = PathBuf::new();
    for part in value.split('/') {
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.trim() != part
            || part.ends_with('.')
            || part.contains(':')
            || part.bytes().any(|b| {
                b < 32
                    || b == 127
                    || b == b'<'
                    || b == b'>'
                    || b == b'|'
                    || b == b'"'
                    || b == b'?'
                    || b == b'*'
            })
        {
            return Err("unsafe update path".into());
        }
        let base = part.split('.').next().unwrap_or("").to_ascii_uppercase();
        if ["CON", "PRN", "AUX", "NUL"].contains(&base.as_str())
            || (base.len() == 4
                && (base.starts_with("COM") || base.starts_with("LPT"))
                && base.as_bytes()[3].is_ascii_digit())
        {
            return Err("reserved update path".into());
        }
        path.push(part);
    }
    Ok(path)
}
pub fn is_redirect(path: &Path) -> Result<bool> {
    let meta = fs::symlink_metadata(path)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return Ok(true);
        }
    }
    Ok(meta.file_type().is_symlink())
}
pub fn checked_join(root: &Path, relative: &str) -> Result<PathBuf> {
    let rel = safe_path(relative)?;
    let mut result = root.to_path_buf();
    for item in rel.components() {
        result.push(item);
        if result.exists() && is_redirect(&result)? {
            return Err("redirected update path".into());
        }
    }
    Ok(result)
}
fn tree(root: &Path, base: &Path, names: &mut HashSet<String>) -> Result<()> {
    for item in fs::read_dir(root)? {
        let item = item?;
        let path = item.path();
        if is_redirect(&path)? {
            return Err("links are not allowed in update packages".into());
        }
        if item.file_type()?.is_dir() {
            tree(&path, base, names)?;
        } else if item.file_type()?.is_file() {
            let name = path
                .strip_prefix(base)?
                .to_str()
                .ok_or("invalid package filename")?
                .replace('\\', "/");
            safe_path(&name)?;
            names.insert(name);
        } else {
            return Err("unsupported package entry".into());
        }
    }
    Ok(())
}
pub fn validate_tree(root: &Path, manifest: &Manifest, contains_manifest: bool) -> Result<()> {
    if is_redirect(root)? {
        return Err("redirected package root".into());
    }
    let mut actual = HashSet::new();
    tree(root, root, &mut actual)?;
    if contains_manifest {
        actual.remove(MANIFEST);
    }
    let expected: HashSet<_> = manifest.files.iter().map(|f| f.path.clone()).collect();
    if actual != expected {
        return Err("package contents do not match manifest".into());
    }
    for f in &manifest.files {
        let path = checked_join(root, &f.path)?;
        if hash_file(&path)? != f.sha256 {
            return Err(format!("package checksum mismatch: {}", f.path).into());
        }
    }
    Ok(())
}
pub fn extract(archive_path: &Path, destination: &Path) -> Result<()> {
    if destination.exists() {
        return Err("extraction folder already exists".into());
    }
    let mut archive = zip::ZipArchive::new(fs::File::open(archive_path)?)?;
    if archive.len() > 20000 {
        return Err("too many zip entries".into());
    }
    let mut total = 0u64;
    let mut names = HashSet::new();
    for i in 0..archive.len() {
        let f = archive.by_index(i)?;
        let raw = f.name()?;
        let name = raw.trim_end_matches('/');
        if name == "__MACOSX" || name.starts_with("__MACOSX/") {
            continue;
        }
        safe_path(name)?;
        let kind = f.unix_mode().unwrap_or(0) & 0o170000;
        if kind != 0 && kind != 0o100000 && kind != 0o040000 {
            return Err("zip links or special files are not allowed".into());
        }
        if !names.insert(name.to_ascii_lowercase()) {
            return Err("duplicate zip entry".into());
        }
        total = total.checked_add(f.size()).ok_or("zip size overflow")?;
        if total > 1024 * 1024 * 1024 {
            return Err("unpacked update is too large".into());
        }
    }
    fs::create_dir(destination)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(destination, fs::Permissions::from_mode(0o700))?;
    }
    for i in 0..archive.len() {
        let mut f = archive.by_index(i)?;
        let name = f.name()?.trim_end_matches('/').to_owned();
        if name == "__MACOSX" || name.starts_with("__MACOSX/") {
            continue;
        }
        let path = checked_join(destination, &name)?;
        if f.is_dir() {
            fs::create_dir_all(&path)?;
            continue;
        }
        fs::create_dir_all(path.parent().ok_or("missing zip parent")?)?;
        let mut output = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        let expected = f.size();
        let count = std::io::copy(&mut f.by_ref().take(expected + 1), &mut output)?;
        if count != expected {
            return Err("zip entry size mismatch".into());
        }
        output.flush()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(
                &path,
                fs::Permissions::from_mode(f.unix_mode().unwrap_or(0o644) & 0o777),
            )?;
        }
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unsafe_paths_are_rejected() {
        for p in [
            "../evil", "/evil", "a/../b", "C:/evil", "a\\b", "NUL.txt", "a.", "a/ /b",
        ] {
            assert!(safe_path(p).is_err(), "{p}");
        }
        assert!(safe_path("Contents/MacOS/PoFig").is_ok());
    }
    #[test]
    fn version_and_manifest_are_bound_to_product() {
        let m = Manifest {
            product: "Other".into(),
            platform: "macos".into(),
            version: "1.0.0".into(),
            files: vec![],
        };
        assert!(m.check("macos", "1.0.0").is_err());
    }
}

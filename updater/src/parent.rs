use crate::Result;

#[cfg(target_os = "macos")]
pub struct Parent(i32);
#[cfg(target_os = "macos")]
impl Parent {
    pub fn open(pid: u32) -> Result<Self> {
        if pid == 0 || pid == std::process::id() {
            return Err("invalid parent process".into());
        }
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let event = libc::kevent {
            ident: pid as usize,
            filter: libc::EVFILT_PROC,
            flags: libc::EV_ADD | libc::EV_ONESHOT,
            fflags: libc::NOTE_EXIT,
            data: 0,
            udata: std::ptr::null_mut(),
        };
        if unsafe { libc::kevent(fd, &event, 1, std::ptr::null_mut(), 0, std::ptr::null()) } < 0 {
            let error = std::io::Error::last_os_error();
            unsafe { libc::close(fd) };
            return Err(error.into());
        }
        Ok(Self(fd))
    }
    pub fn wait(&self) -> Result<()> {
        let mut event = std::mem::MaybeUninit::<libc::kevent>::uninit();
        let timeout = libc::timespec {
            tv_sec: 180,
            tv_nsec: 0,
        };
        let count =
            unsafe { libc::kevent(self.0, std::ptr::null(), 0, event.as_mut_ptr(), 1, &timeout) };
        if count == 1 {
            Ok(())
        } else {
            Err("PoFig did not close in time".into())
        }
    }
}
#[cfg(target_os = "macos")]
impl Drop for Parent {
    fn drop(&mut self) {
        unsafe { libc::close(self.0) };
    }
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut std::ffi::c_void;
    fn WaitForSingleObject(handle: *mut std::ffi::c_void, timeout: u32) -> u32;
    fn CloseHandle(handle: *mut std::ffi::c_void) -> i32;
}
#[cfg(windows)]
pub struct Parent(*mut std::ffi::c_void);
#[cfg(windows)]
impl Parent {
    pub fn open(pid: u32) -> Result<Self> {
        if pid == 0 || pid == std::process::id() {
            return Err("invalid parent process".into());
        }
        let handle = unsafe { OpenProcess(0x00100000, 0, pid) };
        if handle.is_null() {
            Err(std::io::Error::last_os_error().into())
        } else {
            Ok(Self(handle))
        }
    }
    pub fn wait(&self) -> Result<()> {
        if unsafe { WaitForSingleObject(self.0, 180000) } == 0 {
            Ok(())
        } else {
            Err("PoFig did not close in time".into())
        }
    }
}
#[cfg(windows)]
impl Drop for Parent {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

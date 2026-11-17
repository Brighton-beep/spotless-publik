//! Desktop run of the same self-tests (Homebrew libmpv): `cargo run --example selftest -- <fixtures> [url]`.
use std::ffi::{CStr, CString};
fn main() {
    let mut args = std::env::args().skip(1);
    let fx = CString::new(args.next().expect("fixtures dir")).unwrap();
    let url = args.next().map(|u| CString::new(u).unwrap());
    let work = std::env::temp_dir().join("spike-audio-selftest");
    let work = CString::new(work.to_str().unwrap()).unwrap();
    unsafe {
        let r = spike_audio::spike_selftest(
            fx.as_ptr(),
            work.as_ptr(),
            url.as_ref().map_or(std::ptr::null(), |u| u.as_ptr()),
        );
        println!("{}", CStr::from_ptr(r).to_str().unwrap());
        spike_audio::spike_string_free(r);
    }
}

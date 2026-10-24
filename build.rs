// On macOS the Pocket 3's gimbal is driven by gimbal.c (UVC requests through
// IOKit, see its header); elsewhere the camera API's own controls are used.
fn main() {
    println!("cargo:rerun-if-changed=gimbal.c");
    println!("cargo:rerun-if-changed=gimbal.h");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new().file("gimbal.c").warnings(false).compile("gimbal");
        println!("cargo:rustc-link-lib=framework=IOKit");
        println!("cargo:rustc-link-lib=framework=CoreFoundation");
        // The usage strings macOS shows when asking for camera and microphone access.
        let plist = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("Info.plist");
        println!("cargo:rerun-if-changed=Info.plist");
        println!("cargo:rustc-link-arg-bins=-Wl,-sectcreate,__TEXT,__info_plist,{}", plist.display());
    }
}

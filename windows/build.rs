use std::env;

fn main() {
    println!("cargo:rerun-if-changed=assets/WooTodo.ico");
    println!("cargo:rerun-if-changed=app.manifest");

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let host = env::var("HOST").unwrap_or_default();
    if target_os != "windows" || !host.contains("windows") {
        return;
    }

    let mut resource = winresource::WindowsResource::new();
    resource.set_icon("assets/WooTodo.ico");
    resource.set_manifest_file("app.manifest");
    resource.compile().expect("无法编译 Windows 图标与应用清单");
}

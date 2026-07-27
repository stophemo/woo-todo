use std::ffi::{OsStr, OsString, c_void};
use std::mem::size_of;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};
use std::ptr::{null, null_mut};

use windows::Win32::Foundation::PROPERTYKEY;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::{
    CLSCTX_INPROC_SERVER, CoCreateInstance, CoTaskMemFree, IPersistFile,
};
use windows::Win32::UI::Shell::PropertiesSystem::{IPropertyStore, PSCoerceToCanonicalValue};
use windows::Win32::UI::Shell::{
    FOLDERID_Programs, IShellLinkW, KF_FLAG_DEFAULT, SHGetKnownFolderPath, ShellLink,
};
use windows::core::{GUID, Interface, PCWSTR};
use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_WRITE, REG_OPTION_NON_VOLATILE, REG_SZ, RegCloseKey,
    RegCreateKeyExW, RegSetValueExW,
};

const APP_ID: &str = "stophemo.WooTodo";
const PKEY_APP_USER_MODEL_ID: PROPERTYKEY = PROPERTYKEY {
    fmtid: GUID::from_u128(0x9f4c2855_9f79_4b39_a8d0_e1d42de1d5f3),
    pid: 5,
};

pub fn ensure_registered() -> Result<(), String> {
    let executable =
        std::env::current_exe().map_err(|error| format!("无法确定程序路径：{error}"))?;
    create_start_menu_shortcut(&executable)
        .map_err(|error| format!("无法注册系统通知身份：{error}"))?;
    register_protocol(&executable)?;
    Ok(())
}

fn create_start_menu_shortcut(executable: &Path) -> windows::core::Result<()> {
    let shortcut = programs_directory()?.join("Woo Todo.lnk");
    let working_directory = executable.parent().unwrap_or_else(|| Path::new("."));
    let executable = wide_path(executable);
    let working_directory = wide_path(working_directory);
    let shortcut = wide_path(&shortcut);

    unsafe {
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER)?;
        link.SetPath(PCWSTR(executable.as_ptr()))?;
        link.SetWorkingDirectory(PCWSTR(working_directory.as_ptr()))?;
        link.SetIconLocation(PCWSTR(executable.as_ptr()), 0)?;

        let properties: IPropertyStore = link.cast()?;
        let mut app_id = PROPVARIANT::from(APP_ID);
        PSCoerceToCanonicalValue(&PKEY_APP_USER_MODEL_ID, &mut app_id)?;
        properties.SetValue(&PKEY_APP_USER_MODEL_ID, &app_id)?;
        properties.Commit()?;

        let persist: IPersistFile = link.cast()?;
        persist.Save(PCWSTR(shortcut.as_ptr()), true)
    }
}

fn programs_directory() -> windows::core::Result<PathBuf> {
    unsafe {
        let path = SHGetKnownFolderPath(&FOLDERID_Programs, KF_FLAG_DEFAULT, None)?;
        let directory = PathBuf::from(OsString::from_wide(path.as_wide()));
        CoTaskMemFree(Some(path.as_ptr().cast::<c_void>()));
        Ok(directory)
    }
}

fn register_protocol(executable: &Path) -> Result<(), String> {
    set_registry_string("Software\\Classes\\wootodo", None, "URL:Woo Todo Protocol")?;
    set_registry_string("Software\\Classes\\wootodo", Some("URL Protocol"), "")?;
    let mut icon = OsString::from("\"");
    icon.push(executable);
    icon.push("\",0");
    set_registry_os_string("Software\\Classes\\wootodo\\DefaultIcon", None, &icon)?;
    let mut command = OsString::from("\"");
    command.push(executable);
    command.push("\" --uri \"%1\"");
    set_registry_os_string(
        "Software\\Classes\\wootodo\\shell\\open\\command",
        None,
        &command,
    )
}

fn set_registry_string(subkey: &str, value_name: Option<&str>, value: &str) -> Result<(), String> {
    set_registry_os_string(subkey, value_name, OsStr::new(value))
}

fn set_registry_os_string(
    subkey: &str,
    value_name: Option<&str>,
    value: &OsStr,
) -> Result<(), String> {
    let subkey_wide = wide(subkey);
    let value_name_wide = value_name.map(wide);
    let value_wide = value.encode_wide().chain(Some(0)).collect::<Vec<_>>();
    let byte_length = value_wide
        .len()
        .checked_mul(size_of::<u16>())
        .and_then(|length| u32::try_from(length).ok())
        .ok_or_else(|| format!("注册表值过长：{subkey}"))?;
    let mut key: HKEY = null_mut();
    let status = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            subkey_wide.as_ptr(),
            0,
            null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            null(),
            &mut key,
            null_mut(),
        )
    };
    if status != ERROR_SUCCESS {
        return Err(format!("无法创建注册表项 {subkey}（错误 {status}）"));
    }

    let name = value_name_wide
        .as_ref()
        .map_or(null(), |source| source.as_ptr());
    let status = unsafe {
        RegSetValueExW(
            key,
            name,
            0,
            REG_SZ,
            value_wide.as_ptr().cast::<u8>(),
            byte_length,
        )
    };
    unsafe {
        RegCloseKey(key);
    }
    if status != ERROR_SUCCESS {
        return Err(format!("无法写入注册表项 {subkey}（错误 {status}）"));
    }
    Ok(())
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

fn wide_path(value: &Path) -> Vec<u16> {
    value.as_os_str().encode_wide().chain(Some(0)).collect()
}

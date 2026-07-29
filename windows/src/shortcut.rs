use std::collections::{BTreeMap, HashMap};
use std::ops::{BitOr, BitOrAssign};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub enum ShortcutCommand {
    QuickAdd,
    ToggleTaskPanel,
    ToggleAlwaysOnTop,
    ToggleClickThrough,
}

impl ShortcutCommand {
    pub const ALL: [Self; 4] = [
        Self::QuickAdd,
        Self::ToggleTaskPanel,
        Self::ToggleAlwaysOnTop,
        Self::ToggleClickThrough,
    ];
}

/// 数值与 Win32 `MOD_ALT`、`MOD_CONTROL`、`MOD_SHIFT` 和 `MOD_WIN` 保持一致。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ShortcutModifiers(u32);

impl ShortcutModifiers {
    pub const ALT: Self = Self(0x0001);
    pub const CONTROL: Self = Self(0x0002);
    pub const SHIFT: Self = Self(0x0004);
    pub const WINDOWS: Self = Self(0x0008);
    pub const VALID_BITS: u32 = Self::ALT.0 | Self::CONTROL.0 | Self::SHIFT.0 | Self::WINDOWS.0;

    pub const fn bits(self) -> u32 {
        self.0
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub const fn has_only_valid_bits(self) -> bool {
        self.0 & !Self::VALID_BITS == 0
    }
}

impl BitOr for ShortcutModifiers {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Self::Output {
        Self(self.0 | rhs.0)
    }
}

impl BitOrAssign for ShortcutModifiers {
    fn bitor_assign(&mut self, rhs: Self) {
        self.0 |= rhs.0;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ShortcutBinding {
    pub modifiers: ShortcutModifiers,
    pub virtual_key: u32,
}

impl ShortcutBinding {
    pub const fn new(modifiers: ShortcutModifiers, virtual_key: u32) -> Self {
        Self {
            modifiers,
            virtual_key,
        }
    }

    pub fn validate(self) -> Result<(), ShortcutConfigurationError> {
        if self.modifiers.is_empty() {
            return Err(ShortcutConfigurationError::MissingModifier);
        }
        if !self.modifiers.has_only_valid_bits() {
            return Err(ShortcutConfigurationError::InvalidModifier);
        }
        if self.virtual_key == 0 || self.virtual_key > 0xfe {
            return Err(ShortcutConfigurationError::MissingKey);
        }
        if is_modifier_virtual_key(self.virtual_key) {
            return Err(ShortcutConfigurationError::ModifierKey);
        }
        if is_reserved_virtual_key(self.virtual_key) {
            return Err(ShortcutConfigurationError::ReservedKey);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ShortcutConfiguration {
    pub bindings: BTreeMap<ShortcutCommand, ShortcutBinding>,
}

impl Default for ShortcutConfiguration {
    fn default() -> Self {
        let modifiers = ShortcutModifiers::CONTROL | ShortcutModifiers::ALT;
        Self {
            bindings: [
                (
                    ShortcutCommand::QuickAdd,
                    ShortcutBinding::new(modifiers, 0x31),
                ),
                (
                    ShortcutCommand::ToggleTaskPanel,
                    ShortcutBinding::new(modifiers, 0x32),
                ),
                (
                    ShortcutCommand::ToggleAlwaysOnTop,
                    ShortcutBinding::new(modifiers, 0x33),
                ),
                (
                    ShortcutCommand::ToggleClickThrough,
                    ShortcutBinding::new(modifiers, 0x34),
                ),
            ]
            .into_iter()
            .collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShortcutConfigurationError {
    MissingCommand(ShortcutCommand),
    MissingModifier,
    InvalidModifier,
    MissingKey,
    ModifierKey,
    ReservedKey,
    Duplicate {
        command: ShortcutCommand,
        conflicts_with: ShortcutCommand,
    },
}

impl ShortcutConfiguration {
    pub fn binding(&self, command: ShortcutCommand) -> Option<&ShortcutBinding> {
        self.bindings.get(&command)
    }

    pub fn validate(&self) -> Result<(), ShortcutConfigurationError> {
        let mut owners = HashMap::new();
        for command in ShortcutCommand::ALL {
            let binding = self
                .binding(command)
                .copied()
                .ok_or(ShortcutConfigurationError::MissingCommand(command))?;
            binding.validate()?;
            let chord = (binding.modifiers, binding.virtual_key);
            if let Some(owner) = owners.insert(chord, command) {
                return Err(ShortcutConfigurationError::Duplicate {
                    command,
                    conflicts_with: owner,
                });
            }
        }
        if self.bindings.len() != ShortcutCommand::ALL.len() {
            return Err(ShortcutConfigurationError::InvalidModifier);
        }
        Ok(())
    }
}

fn is_modifier_virtual_key(virtual_key: u32) -> bool {
    matches!(
        virtual_key,
        0x10 // VK_SHIFT
            | 0x11 // VK_CONTROL
            | 0x12 // VK_MENU
            | 0x5b // VK_LWIN
            | 0x5c // VK_RWIN
            | 0xa0 // VK_LSHIFT
            | 0xa1 // VK_RSHIFT
            | 0xa2 // VK_LCONTROL
            | 0xa3 // VK_RCONTROL
            | 0xa4 // VK_LMENU
            | 0xa5 // VK_RMENU
    )
}

fn is_reserved_virtual_key(virtual_key: u32) -> bool {
    // Windows 明确保留 F12 供调试器使用，应用不应注册它作为全局快捷键。
    virtual_key == 0x7b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_contain_all_four_commands() {
        let configuration = ShortcutConfiguration::default();
        assert_eq!(configuration.bindings.len(), 4);
        assert_eq!(configuration.validate(), Ok(()));

        for (offset, command) in ShortcutCommand::ALL.into_iter().enumerate() {
            assert_eq!(
                configuration.binding(command),
                Some(&ShortcutBinding::new(
                    ShortcutModifiers::CONTROL | ShortcutModifiers::ALT,
                    0x31 + offset as u32
                ))
            );
        }
    }

    #[test]
    fn missing_modifier_key_and_reserved_key_are_rejected() {
        assert_eq!(
            ShortcutBinding::new(ShortcutModifiers::default(), 0x41).validate(),
            Err(ShortcutConfigurationError::MissingModifier)
        );
        assert_eq!(
            ShortcutBinding::new(ShortcutModifiers::CONTROL, 0).validate(),
            Err(ShortcutConfigurationError::MissingKey)
        );
        assert_eq!(
            ShortcutBinding::new(ShortcutModifiers::CONTROL, 0x11).validate(),
            Err(ShortcutConfigurationError::ModifierKey)
        );
        assert_eq!(
            ShortcutBinding::new(ShortcutModifiers::CONTROL, 0x7b).validate(),
            Err(ShortcutConfigurationError::ReservedKey)
        );
    }

    #[test]
    fn duplicate_and_missing_commands_are_rejected() {
        let mut duplicate = ShortcutConfiguration::default();
        duplicate.bindings.insert(
            ShortcutCommand::ToggleTaskPanel,
            *duplicate.binding(ShortcutCommand::QuickAdd).unwrap(),
        );
        assert!(matches!(
            duplicate.validate(),
            Err(ShortcutConfigurationError::Duplicate { .. })
        ));

        let mut missing = ShortcutConfiguration::default();
        missing.bindings.remove(&ShortcutCommand::QuickAdd);
        assert_eq!(
            missing.validate(),
            Err(ShortcutConfigurationError::MissingCommand(
                ShortcutCommand::QuickAdd
            ))
        );
    }

    #[test]
    fn configuration_round_trips_through_json() {
        let mut configuration = ShortcutConfiguration::default();
        configuration.bindings.insert(
            ShortcutCommand::QuickAdd,
            ShortcutBinding::new(ShortcutModifiers::CONTROL | ShortcutModifiers::SHIFT, 0x51),
        );

        let source = serde_json::to_string(&configuration).unwrap();
        let restored: ShortcutConfiguration = serde_json::from_str(&source).unwrap();

        assert_eq!(restored, configuration);
        assert_eq!(restored.validate(), Ok(()));
    }
}

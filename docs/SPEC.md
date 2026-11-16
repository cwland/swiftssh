# Project Specification: SwiftSSH, a Native macOS SSH Client

## 1. Project Overview & Goals
Build a native macOS SSH client and terminal emulator with a modern design, a smooth workflow and careful visual polish. 
- **Target Platform:** macOS 15.0+ (Sequoia and later) built with Swift and SwiftUI (with AppKit bridging where required for low-level terminal rendering and window management).
- **Future-Proofing:** Architect the data models, SSH networking engine, and iCloud sync layer as a shared Swift Package (`CoreSSH`) so an iOS/iPadOS companion app can be built on top of the exact same core later.
- **Scope:** Focus strictly on core SSH, SFTP, host management, snippets, port forwarding, and seamless cross-Mac credential syncing via Apple's iCloud ecosystem. Exclude team collaboration features, multiplayer terminals, and custom cloud accounts.

---

## 2. Tech Stack & Recommended Libraries
- **UI Framework:** SwiftUI (primary layout, sidebar, modals, settings) + AppKit (`NSViewRepresentable` for the terminal canvas and custom window titlebar).
- **Terminal Emulation:** `SwiftTerm` (by Miguel de Icaza) for high-performance VT100/xterm-256color emulation, PTY handling, mouse reporting, and ANSI escape sequences.
- **SSH & SFTP Engine:** `Citadel` (built on `swift-nio-ssh`) or `libssh2` Swift wrapper. Must support SSH-2, Ed25519, ECDSA, RSA, password auth, keyboard-interactive, SSH Agent forwarding, and SFTP file transfers.
- **Local Persistence & Sync:** `SwiftData` backed by **CloudKit** (`NSPersistentCloudKitContainer`) for host metadata, groups, and snippets.
- **Credential & Key Sync:** Apple **iCloud Keychain** (`Security` framework with `kSecAttrSynchronizable: true`) for passwords, SSH private keys, and passphrases.

---

## 3. UI/UX & Visual Design
A modern, dark-first, high-contrast developer aesthetic:
- **Color Palette & Theme:**
  - Deep slate/navy-charcoal base (`#14171F` background, `#1C202B` elevated cards/sidebars, `#252A37` hover states, `#00D1B2` / `#3B82F6` vibrant teal/blue primary accents).
  - Support custom terminal color themes (Dracula, Solarized Dark/Light, Monokai, Nord, a default dark theme) decoupled from the app chrome.
- **Window & Navigation Architecture:**
  - **Unified Titlebar with Horizontal Tabs:** Top bar merges window controls with a browser-style tab strip for active terminal sessions, SFTP sessions, and the main "Vault" management tab.
  - **Left Navigation Sidebar (Collapsible):**
    - **Hosts** (Primary grid/list view with nested Groups)
    - **Keychain** (Centralized repository of SSH keys, passwords, and identities)
    - **Port Forwarding** (Local, Remote, Dynamic SOCKS5 rules)
    - **Snippets** (Reusable shell commands/scripts)
    - **Known Hosts** (Fingerprint management)
  - **Host Cards & Grouping:**
    - Hosts displayed as clean, scannable cards showing OS badge icon (Ubuntu, Debian, macOS, Linux, AWS, etc. — auto-detected on first connect), Host alias/label, IP/Hostname, and username.
    - Support nested **Groups** (folders) with breadcrumbs and tag filtering.
  - **Right Inspector Drawer (Slide-over):**
    - Clicking "Edit" on a Host or Key opens a sleek right-hand slide-over inspector panel (not a blocking modal) to configure IP, port, credentials, jump hosts, startup snippets, and terminal theme.
  - **Command Palette (`Cmd + K`):**
    - Global fuzzy-search modal to immediately connect to any host, run a snippet, or open SFTP without touching the mouse.

---

## 4. Core Functional Requirements

### 4.1 Terminal Experience
- **Multi-Tab & Split Panes:** Open multiple sessions in tabs or split any terminal tab horizontally/vertically into multiple panes.
- **Right-Side Terminal Drawer:** Toggleable in-session drawer providing one-click access to **Snippets** (click to paste or execute immediately) and **Terminal Theme/Font settings**.
- **Connection Resiliency:** Automatic reconnect prompt on dropped connections; keep scrollback buffer intact.
- **Clipboard & Drag-and-Drop:** Support OSC 52 clipboard integration, copy-on-select, and dragging a local file onto the terminal window to automatically upload it via SFTP to the current working directory.

### 4.2 Centralized Keychain
- Credentials are **decoupled** from Hosts. A user creates a Keychain item once (e.g., "Production Root Key" or "Staging Password") and links it to multiple Hosts or Groups.
- Updating a password or rotating a key in the Keychain automatically updates all linked Hosts.
- Support generating new `Ed25519` and `RSA-4096` keypairs in-app, importing existing PEM/OpenSSH keys, and one-click `ssh-copy-id` deployment to a host.

### 4.3 Integrated SFTP Client
- Dual-pane file browser (Local filesystem on left, Remote host on right) accessible as a tab or directly from an active SSH session.
- Drag-and-drop uploads/downloads, directory creation, permissions (`chmod`) editor, and quick-edit of remote text/config files in the user's default local editor.

### 4.4 Jump Hosts (Bastion) & Port Forwarding
- **SSH Chaining:** Allow any Host to specify another saved Host as a Jump Host (`ProxyJump`).
- **Port Forwarding:** Visual configuration for Local (`-L`), Remote (`-R`), and Dynamic (`-D` SOCKS5) tunnels that can be toggled on/off independently or tied to a Host connection.

---

## 5. iCloud Sync & Security Architecture
Because sensitive credentials cannot be stored in plain text in CloudKit, split sync into two native Apple mechanisms:

1. **Non-Sensitive Metadata (CloudKit via SwiftData):**
   - Syncs `Host` (alias, hostname, port, username, OS type, group ID, keychain item UUID reference, theme ID), `HostGroup`, `Snippet`, and `PortForwardRule`.
   - Uses private CloudKit database (`CKContainer.default().privateCloudDatabase`) so data stays strictly in the user's iCloud account.
2. **Sensitive Secrets (iCloud Keychain):**
   - Store private keys, key passphrases, and passwords in the macOS Keychain using `SecItemAdd` / `SecItemUpdate` with `kSecAttrSynchronizable: kCFBooleanTrue`.
   - Keychain items are indexed by the `UUID` referenced in the SwiftData `KeychainIdentity` model.
   - **Biometric Gate:** Require Touch ID / Apple Watch / macOS password (`LAContext`) on app launch (configurable timeout) before reading private keys or passwords from the Keychain.

---

## 6. Data Models (SwiftData Schema Draft)

```swift
@Model
final class Host {
    var id: UUID = UUID()
    var label: String = ""
    var hostname: String = ""
    var port: Int = 22
    var username: String = "root"
    var osIconName: String = "terminal"
    var tags: [String] = []
    var keychainIdentityID: UUID? // Maps to iCloud Keychain item
    var jumpHostID: UUID?
    var startupSnippetID: UUID?
    var terminalTheme: String = "DefaultDark"
    var group: HostGroup?
    var lastConnectedAt: Date?
}

@Model
final class HostGroup {
    var id: UUID = UUID()
    var name: String = ""
    var iconName: String = "folder"
    var parentGroup: HostGroup?
    @Relationship(deleteRule: .cascade, inverse: \HostGroup.parentGroup)
    var subGroups: [HostGroup] = []
    @Relationship(deleteRule: .nullify, inverse: \Host.group)
    var hosts: [Host] = []
}

@Model
final class KeychainIdentity {
    var id: UUID = UUID() // Shared key used in kSecAttrAccount for iCloud Keychain lookup
    var label: String = ""
    var authType: String = "key" // "password", "key", "agent"
    var publicKey: String? // Safe to store in CloudKit for easy copy/export
    var keyType: String? // "ed25519", "rsa"
    var createdAt: Date = Date()
}

@Model
final class Snippet {
    var id: UUID = UUID()
    var title: String = ""
    var script: String = ""
    var tags: [String] = []
}
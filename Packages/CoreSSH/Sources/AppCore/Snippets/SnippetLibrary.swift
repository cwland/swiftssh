import Foundation
import Observation
import CoreModels

/// Ready-made snippets for common server admin jobs ("New Snippet from Library…"). Adding one makes an
/// ordinary snippet in a package named after its category; from then on it is the user's to edit.
///
/// Rules for entries: one line; mostly read-only; anything that changes the server (restart, stop,
/// kill, install) asks for its target with a `{{placeholder}}`; nothing that wipes data. Docker's own
/// `{{.Field}}` templates stay literal (a placeholder name can't start with a dot).
public enum SnippetLibrary {
    public struct Entry: Identifiable, Hashable, Sendable {
        /// Stable: "<category>.<name>".
        public let id: String
        public let category: String
        public let name: String
        /// One line on what it shows or does.
        public let detail: String
        public let script: String
    }

    public static let categories = [
        "System", "Disk", "Processes", "Network", "Services", "Logs", "Docker", "Packages",
        "Users & Security", "Files",
    ]

    private static func e(_ id: String, _ category: String, _ name: String, _ detail: String, _ script: String) -> Entry {
        Entry(id: id, category: category, name: name, detail: detail, script: script)
    }

    public static let entries: [Entry] = [
        // System
        e("system.uptime", "System", "Uptime and load", "How long the server has been up and its load averages.", "uptime"),
        e("system.os", "System", "OS version", "Distribution name and version.", "cat /etc/os-release"),
        e("system.kernel", "System", "Kernel and architecture", "Kernel release, architecture and hostname.", "uname -a"),
        e("system.memory", "System", "Memory usage", "Used, free and cached memory in human units.", "free -h"),
        e("system.cpu", "System", "CPU info", "CPU model, cores and threads.", "lscpu"),
        e("system.hostname", "System", "Host name and time", "Host name, time zone and clock sync status.", "hostnamectl; timedatectl"),
        e("system.lastboot", "System", "Recent reboots", "When the server last rebooted.", "last -x reboot | head -n 10"),
        e("system.rebootrequired", "System", "Reboot required?", "Whether updates are waiting for a reboot (Debian/Ubuntu).", "[ -f /var/run/reboot-required ] && cat /var/run/reboot-required || echo 'No reboot required'"),

        // Disk
        e("disk.usage", "Disk", "Disk usage", "Free space on every mounted filesystem.", "df -h"),
        e("disk.inodes", "Disk", "Inode usage", "Free inodes per filesystem (full inodes block new files).", "df -i"),
        e("disk.biggest", "Disk", "Biggest folders", "The largest folders in a directory.", "du -h --max-depth=1 {{path:/var}} 2>/dev/null | sort -rh | head -n 20"),
        e("disk.bigfiles", "Disk", "Files over a size", "Files larger than a size under a directory.", "find {{path:/}} -xdev -type f -size +{{size:500M}} -exec ls -lh {} + 2>/dev/null | sort -k5 -rh | head -n 20"),
        e("disk.blocks", "Disk", "Disks and partitions", "Block devices, sizes and mount points.", "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT"),
        e("disk.mounts", "Disk", "Mounted filesystems", "What is mounted where.", "findmnt --real"),

        // Processes
        e("processes.topcpu", "Processes", "Top CPU processes", "The 15 processes using the most CPU.", "ps aux --sort=-%cpu | head -n 16"),
        e("processes.topmem", "Processes", "Top memory processes", "The 15 processes using the most memory.", "ps aux --sort=-%mem | head -n 16"),
        e("processes.find", "Processes", "Find a process", "Processes whose command line matches a name.", "pgrep -af {{name}}"),
        e("processes.tree", "Processes", "Process tree", "Every process as a tree.", "ps -ef --forest"),
        e("processes.kill", "Processes", "Stop a process", "Asks a process to stop (SIGTERM).", "kill {{pid}}"),
        e("processes.top", "Processes", "Live overview", "htop if installed, otherwise top.", "command -v htop >/dev/null && htop || top"),

        // Network
        e("network.ip", "Network", "IP addresses", "Every interface with its addresses.", "ip -brief address"),
        e("network.routes", "Network", "Routes", "The routing table and default gateway.", "ip route"),
        e("network.listening", "Network", "Listening ports", "TCP and UDP ports open for connections, with their process.", "sudo ss -tulpn"),
        e("network.connections", "Network", "Open connections", "Established TCP connections.", "ss -tnp state established"),
        e("network.publicip", "Network", "Public IP", "The address this server reaches the internet from.", "curl -s https://ifconfig.me; echo"),
        e("network.dns", "Network", "DNS lookup", "Looks up a name's addresses.", "getent ahosts {{name:example.com}}"),
        e("network.ping", "Network", "Ping a host", "Five pings to a host.", "ping -c 5 {{host:1.1.1.1}}"),
        e("network.port", "Network", "Test a port", "Checks whether a TCP port answers.", "nc -zv -w 3 {{host}} {{port}}"),
        e("network.firewall", "Network", "Firewall rules", "ufw status if present, otherwise nftables rules.", "command -v ufw >/dev/null && sudo ufw status verbose || sudo nft list ruleset"),

        // Services
        e("services.failed", "Services", "Failed services", "systemd units that failed.", "systemctl --failed"),
        e("services.running", "Services", "Running services", "systemd services that are running.", "systemctl list-units --type=service --state=running"),
        e("services.status", "Services", "Service status", "Status and recent log lines of a service.", "systemctl status {{service}} --no-pager"),
        e("services.restart", "Services", "Restart a service", "Restarts a service, then shows its status.", "sudo systemctl restart {{service}} && systemctl status {{service}} --no-pager"),
        e("services.timers", "Services", "Scheduled timers", "systemd timers and when they run next.", "systemctl list-timers"),
        e("services.cron", "Services", "My cron jobs", "This account's crontab.", "crontab -l"),

        // Logs
        e("logs.follow", "Logs", "Follow a service log", "A service's log as it is written.", "journalctl -u {{service}} -f"),
        e("logs.errors", "Logs", "Errors since boot", "Error-level messages since the last boot.", "journalctl -p err -b --no-pager | tail -n 50"),
        e("logs.recent", "Logs", "Last hour of logs", "Everything logged in the last hour.", "journalctl --since '1 hour ago' --no-pager"),
        e("logs.kernel", "Logs", "Kernel messages", "The latest kernel messages (hardware, OOM kills).", "sudo dmesg -T | tail -n 50"),
        e("logs.auth", "Logs", "Login attempts", "Recent SSH logins and failures.", "journalctl -u ssh -u sshd --since today --no-pager | grep -Ei 'accepted|failed' | tail -n 40"),
        e("logs.size", "Logs", "Journal disk use", "How much space the systemd journal takes.", "journalctl --disk-usage"),

        // Docker
        e("docker.ps", "Docker", "Running containers", "Containers with their status and ports.", "docker ps --format 'table {{.Names}}\\t{{.Status}}\\t{{.Ports}}'"),
        e("docker.all", "Docker", "All containers", "Every container, also stopped ones.", "docker ps -a"),
        e("docker.stats", "Docker", "Container resources", "CPU and memory per container, once.", "docker stats --no-stream"),
        e("docker.logs", "Docker", "Follow container logs", "The last 100 lines of a container's log, then new ones.", "docker logs -f --tail 100 {{container}}"),
        e("docker.shell", "Docker", "Shell in a container", "Opens a shell inside a running container.", "docker exec -it {{container}} sh"),
        e("docker.restart", "Docker", "Restart a container", "Restarts one container.", "docker restart {{container}}"),
        e("docker.composeup", "Docker", "Compose up", "Starts or updates a Compose project in the background.", "cd {{folder}} && docker compose up -d"),
        e("docker.composepull", "Docker", "Compose pull and update", "Pulls newer images for a Compose project and recreates what changed.", "cd {{folder}} && docker compose pull && docker compose up -d"),
        e("docker.disk", "Docker", "Docker disk use", "Space used by images, containers and volumes.", "docker system df"),
        e("docker.images", "Docker", "Images", "Local images and their sizes.", "docker images"),

        // Packages
        e("packages.aptupdates", "Packages", "Available updates (apt)", "Refreshes the package lists and shows what can be upgraded.", "sudo apt update && apt list --upgradable"),
        e("packages.aptupgrade", "Packages", "Install updates (apt)", "Installs all available updates (asks before installing).", "sudo apt update && sudo apt upgrade"),
        e("packages.dnfupdates", "Packages", "Available updates (dnf)", "Shows what can be upgraded on Fedora, RHEL and similar.", "sudo dnf check-update"),
        e("packages.installed", "Packages", "Is a package installed?", "Whether a package is installed, on apt or rpm systems.", "dpkg -l {{package}} 2>/dev/null || rpm -q {{package}}"),
        e("packages.install", "Packages", "Install a package (apt)", "Installs a package (asks before installing).", "sudo apt install {{package}}"),

        // Users & Security
        e("security.who", "Users & Security", "Who is logged in", "Logged-in users and what they are running.", "w"),
        e("security.lastlogins", "Users & Security", "Recent logins", "The last 20 logins.", "last -n 20"),
        e("security.failedlogins", "Users & Security", "Failed logins", "Recent failed login attempts.", "sudo lastb -n 20"),
        e("security.sudoers", "Users & Security", "Users with sudo", "Members of the sudo and wheel groups.", "getent group sudo wheel"),
        e("security.user", "Users & Security", "User details", "A user's groups and password expiry.", "id {{user}} && sudo chage -l {{user}}"),
        e("security.fail2ban", "Users & Security", "fail2ban status", "Banned addresses for the SSH jail.", "sudo fail2ban-client status sshd"),
        e("security.sshconfig", "Users & Security", "Effective SSH server settings", "Key sshd settings (root login, passwords, port).", "sudo sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication) '"),

        // Files
        e("files.recent", "Files", "Recently changed files", "Files changed in the last day under a directory.", "find {{path:/etc}} -xdev -type f -mtime -1 2>/dev/null | head -n 50"),
        e("files.search", "Files", "Search text in files", "Lines containing some text under a directory.", "grep -rn --color=always '{{text}}' {{path:.}} 2>/dev/null | head -n 50"),
        e("files.tail", "Files", "Follow a file", "A file's last lines, then new ones.", "tail -n 100 -f {{file}}"),
        e("files.permissions", "Files", "Permissions along a path", "Owner and permissions of every folder down to a file.", "namei -l {{path}}"),
        e("files.archive", "Files", "Archive a folder", "Packs a folder into a dated .tar.gz next to it.", "tar -czf {{folder}}-$(date +%Y%m%d).tar.gz {{folder}}"),
    ]
}

/// "New Snippet from Library…": the catalog by category, with search and check boxes. Entries whose
/// script a snippet already has (not deleted) show as added and can't be checked.
@MainActor
@Observable
public final class SnippetLibraryViewModel {
    public enum CategoryState: Equatable { case none, some, all }

    public struct Section: Identifiable {
        public let category: String
        public let entries: [SnippetLibrary.Entry]
        public var id: String { category }
    }

    /// Matches name, command and description (every word, case-insensitive).
    public var searchText = ""
    public private(set) var selected: Set<String> = []
    @ObservationIgnored private let vault: LocalVault

    public init(vault: LocalVault) {
        self.vault = vault
    }

    public var selectedCount: Int { selected.count }

    /// The categories in catalog order, only those with matching entries.
    public var sections: [Section] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace)
        let matching = SnippetLibrary.entries.filter { entry in
            let haystack = "\(entry.name) \(entry.script) \(entry.detail) \(entry.category)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return SnippetLibrary.categories.compactMap { category in
            let entries = matching.filter { $0.category == category }
            return entries.isEmpty ? nil : Section(category: category, entries: entries)
        }
    }

    private var existingScripts: Set<String> {
        _ = vault.revision
        return Set(vault.all(Snippet.self).map(\.script))
    }

    public func isAdded(_ entry: SnippetLibrary.Entry) -> Bool {
        existingScripts.contains(entry.script)
    }

    public func isSelected(_ entry: SnippetLibrary.Entry) -> Bool {
        selected.contains(entry.id)
    }

    public func toggle(_ entry: SnippetLibrary.Entry) {
        if selected.contains(entry.id) {
            selected.remove(entry.id)
        } else if !isAdded(entry) {
            selected.insert(entry.id)
        }
    }

    /// The category's visible entries that can still be added.
    private func addable(in category: String) -> [SnippetLibrary.Entry] {
        let existing = existingScripts
        return (sections.first { $0.category == category }?.entries ?? []).filter { !existing.contains($0.script) }
    }

    public func categoryState(_ category: String) -> CategoryState {
        let ids = addable(in: category).map(\.id)
        let count = ids.filter(selected.contains).count
        if count == 0 { return .none }
        return count == ids.count ? .all : .some
    }

    /// Checks or unchecks every visible, addable entry of the category.
    public func setCategory(_ category: String, selected on: Bool) {
        for entry in addable(in: category) {
            if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
        }
    }

    /// Creates the checked entries (catalog order) as snippets in a package per category, skipping any
    /// added meanwhile; clears the selection. Returns how many were created.
    @discardableResult
    public func addSelected() -> Int {
        var existing = existingScripts
        var created = 0
        for entry in SnippetLibrary.entries where selected.contains(entry.id) && !existing.contains(entry.script) {
            vault.saveNow(Snippet(name: entry.name, script: entry.script, package: entry.category))
            existing.insert(entry.script)
            created += 1
        }
        selected = []
        return created
    }
}

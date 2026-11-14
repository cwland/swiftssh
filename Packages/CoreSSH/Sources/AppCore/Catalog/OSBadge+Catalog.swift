import CoreModels

/// Named catalog ids (the legacy twelve are declared in CoreModels). Every one is checked against
/// the bundled catalog by the tests.
public extension OSBadge {
    static let windows = OSBadge(rawValue: "windows")
    static let windows10 = OSBadge(rawValue: "windows-10")
    static let apple = OSBadge(rawValue: "apple")
    static let almalinux = OSBadge(rawValue: "almalinux")
    static let rocky = OSBadge(rawValue: "rocky")
    static let centos = OSBadge(rawValue: "centos")
    static let opensuse = OSBadge(rawValue: "opensuse")
    static let linuxmint = OSBadge(rawValue: "linuxmint")
    static let kali = OSBadge(rawValue: "kali")
    static let manjaro = OSBadge(rawValue: "manjaro")
    static let gentoo = OSBadge(rawValue: "gentoo")
    static let nixos = OSBadge(rawValue: "nixos")
    static let pop = OSBadge(rawValue: "pop")
    static let oracle = OSBadge(rawValue: "oracle")
    static let amzn = OSBadge(rawValue: "amzn")
    static let truenas = OSBadge(rawValue: "truenas")
    static let unraid = OSBadge(rawValue: "unraid")
    static let qnap = OSBadge(rawValue: "qnap")
    static let openmediavault = OSBadge(rawValue: "openmediavault")
    static let asustor = OSBadge(rawValue: "asustor")
    static let terramaster = OSBadge(rawValue: "terramaster")
    static let casaos = OSBadge(rawValue: "casaos")
    static let umbrel = OSBadge(rawValue: "umbrel")
    static let pfsense = OSBadge(rawValue: "pfsense")
    static let opnsense = OSBadge(rawValue: "opnsense")
    static let openwrt = OSBadge(rawValue: "openwrt")
    static let mikrotik = OSBadge(rawValue: "mikrotik")
    static let ubiquiti = OSBadge(rawValue: "ubiquiti")
    static let cisco = OSBadge(rawValue: "cisco")
    static let vyos = OSBadge(rawValue: "vyos")
    static let sophos = OSBadge(rawValue: "sophos")
    static let fortinet = OSBadge(rawValue: "fortinet")
    static let proxmox = OSBadge(rawValue: "proxmox")
    static let vmware = OSBadge(rawValue: "vmware")
    static let xcpng = OSBadge(rawValue: "xcpng")
    static let docker = OSBadge(rawValue: "docker")
    static let openbsd = OSBadge(rawValue: "openbsd")
    static let netbsd = OSBadge(rawValue: "netbsd")

    /// Every named constant (CoreModels' twelve and these), for tests.
    internal static var namedCatalogConstants: [OSBadge] {
        [.ubuntu, .debian, .raspbian, .fedora, .rhel, .alpine, .arch, .macos, .freebsd, .linux, .synology,
         .homeAssistant,
         .windows, .windows10, .apple, .almalinux, .rocky, .centos, .opensuse, .linuxmint, .kali, .manjaro,
         .gentoo, .nixos, .pop, .oracle, .amzn, .truenas, .unraid, .qnap, .openmediavault, .asustor,
         .terramaster, .casaos, .umbrel, .pfsense, .opnsense, .openwrt, .mikrotik, .ubiquiti, .cisco, .vyos,
         .sophos, .fortinet, .proxmox, .vmware, .xcpng, .docker, .openbsd, .netbsd]
    }
}

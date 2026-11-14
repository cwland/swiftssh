import XCTest
import CoreModels
@testable import AppCore

final class OSDetectorTests: XCTestCase {
    /// What the probe prints on a POSIX host: the outer echo, uname, os-release, then markers.
    private func posix(_ uname: String = "Linux", _ osRelease: String = "", markers: [String] = []) -> String {
        "TR_OS_ENV=%OS%\n\(uname)\n" + osRelease + markers.map { "TR_OS=\($0)\n" }.joined()
    }

    private func detect(_ output: String) -> OSBadge? { OSDetector.badge(fromProbeOutput: output) }

    // MARK: os-release ID

    func testOSReleaseIDs() {
        let cases: [(String, OSBadge)] = [
            ("PRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nNAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nID=ubuntu\nID_LIKE=debian\n", .ubuntu),
            ("PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"\nNAME=\"Debian GNU/Linux\"\nVERSION_ID=\"12\"\nID=debian\n", .debian),
            ("NAME=\"Red Hat Enterprise Linux\"\nVERSION=\"9.4 (Plow)\"\nID=\"rhel\"\nID_LIKE=\"fedora\"\n", .rhel),
            ("NAME=\"Fedora Linux\"\nVERSION=\"40 (Server Edition)\"\nID=fedora\nVERSION_ID=40\n", .fedora),
            ("NAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\nID=arch\nBUILD_ID=rolling\n", .arch),
            ("NAME=\"AlmaLinux\"\nVERSION=\"9.4 (Seafoam Ocelot)\"\nID=\"almalinux\"\nID_LIKE=\"rhel centos fedora\"\n", .almalinux),
            ("NAME=\"Rocky Linux\"\nVERSION=\"9.4 (Blue Onyx)\"\nID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n", .rocky),
            ("NAME=\"CentOS Stream\"\nVERSION=\"9\"\nID=\"centos\"\nID_LIKE=\"rhel fedora\"\n", .centos),
            ("NAME=\"Alpine Linux\"\nID=alpine\nVERSION_ID=3.20.3\n", .alpine),
            ("NAME=\"openSUSE Leap\"\nVERSION=\"15.6\"\nID=\"opensuse-leap\"\nID_LIKE=\"suse opensuse\"\n", .opensuse),
            ("NAME=\"openSUSE Tumbleweed\"\nID=\"opensuse-tumbleweed\"\nID_LIKE=\"opensuse suse\"\n", .opensuse),
            ("NAME=\"SLES\"\nVERSION=\"15-SP6\"\nID=\"sles\"\nID_LIKE=\"suse\"\n", .opensuse),
            ("NAME=\"Linux Mint\"\nVERSION=\"22 (Wilma)\"\nID=linuxmint\nID_LIKE=\"ubuntu debian\"\n", .linuxmint),
            ("PRETTY_NAME=\"Kali GNU/Linux Rolling\"\nNAME=\"Kali GNU/Linux\"\nID=kali\nID_LIKE=debian\n", .kali),
            ("NAME=\"Manjaro Linux\"\nID=manjaro\nID_LIKE=arch\n", .manjaro),
            ("NAME=\"Manjaro ARM\"\nID=\"manjaro-arm\"\nID_LIKE=\"manjaro arch\"\n", .manjaro),
            ("NAME=Gentoo\nID=gentoo\nPRETTY_NAME=\"Gentoo Linux\"\n", .gentoo),
            ("NAME=NixOS\nID=nixos\nVERSION=\"24.05 (Uakari)\"\n", .nixos),
            ("NAME=\"Pop!_OS\"\nVERSION=\"22.04 LTS\"\nID=pop\nID_LIKE=\"ubuntu debian\"\n", .pop),
            ("PRETTY_NAME=\"Raspbian GNU/Linux 12 (bookworm)\"\nNAME=\"Raspbian GNU/Linux\"\nID=raspbian\nID_LIKE=debian\n", .raspbian),
            ("NAME=\"Oracle Linux Server\"\nVERSION=\"9.4\"\nID=\"ol\"\nID_LIKE=\"fedora\"\n", .oracle),
            ("NAME=\"Amazon Linux\"\nVERSION=\"2023\"\nID=\"amzn\"\nID_LIKE=\"fedora\"\n", .amzn),
            ("NAME=\"OpenWrt\"\nVERSION=\"23.05.4\"\nID=\"openwrt\"\nID_LIKE=\"lede openwrt\"\n", .openwrt),
            ("PRETTY_NAME=\"VyOS 1.4.0 (sagitta)\"\nNAME=\"VyOS\"\nID=vyos\nID_LIKE=debian\n", .vyos),
            ("NAME=\"XCP-ng\"\nVERSION=\"8.2.1\"\nID=\"xenenterprise\"\nID_LIKE=\"centos rhel fedora\"\n", .xcpng),
            ("NAME=\"Home Assistant OS\"\nVERSION=\"13.1\"\nID=\"haos\"\nID_LIKE=\"buildroot\"\n", .homeAssistant),
        ]
        for (osRelease, expected) in cases {
            XCTAssertEqual(detect(posix("Linux", osRelease)), expected, osRelease)
        }
    }

    // MARK: ID_LIKE

    func testIDLikeFallbackWhenIDIsUnknown() {
        XCTAssertEqual(detect(posix("Linux", "NAME=\"EndeavourOS\"\nID=\"endeavouros\"\nID_LIKE=\"arch\"\n")), .arch)
        XCTAssertEqual(detect(posix("Linux", "NAME=\"Zorin OS\"\nID=zorin\nID_LIKE=\"ubuntu debian\"\n")), .ubuntu)
        // elementary OS is not in the catalog: its ID_LIKE decides.
        XCTAssertEqual(detect(posix("Linux", "NAME=\"elementary OS\"\nVERSION=\"7.1 Horus\"\nID=elementary\nID_LIKE=ubuntu\n")), .ubuntu)
        XCTAssertEqual(detect(posix("Linux", "NAME=\"Deepin\"\nID=deepin\nID_LIKE=debian\n")), .debian)
        XCTAssertEqual(detect(posix("Linux", "NAME=\"Navy Linux\"\nID=navy\nID_LIKE=\"rhel fedora\"\n")), .rhel)
        XCTAssertEqual(detect(posix("Linux", "NAME=\"GeckoLinux\"\nID=gecko\nID_LIKE=\"suse\"\n")), .opensuse)
        XCTAssertEqual(detect(posix("Linux", "ID=weird\nID_LIKE=\"buildroot nothing\"\n")), .linux)
    }

    // MARK: Markers

    func testMarkers() {
        let cases: [(String, String, String, OSBadge)] = [
            // uname, os-release, marker, expected
            ("Linux", "", "synology", .synology),                                  // DSM: no os-release
            ("Linux", "NAME=\"Unraid\"\nID=unraid\n", "unraid", .unraid),
            ("Linux", "NAME=\"Debian GNU/Linux\"\nID=debian\n", "truenas", .truenas), // SCALE
            ("FreeBSD", "", "truenas", .truenas),                                  // CORE
            ("Linux", "", "qnap", .qnap),                                          // QTS: no os-release
            ("Linux", "NAME=\"Debian GNU/Linux\"\nID=debian\n", "openmediavault", .openmediavault),
            ("Linux", "NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n", "casaos", .casaos),
            ("Linux", "NAME=\"Debian GNU/Linux\"\nID=debian\n", "umbrel", .umbrel),
            ("Linux", "NAME=\"Debian GNU/Linux\"\nID=debian\n", "proxmox", .proxmox),
            ("Linux", "NAME=\"XCP-ng\"\nID=\"xenenterprise\"\n", "xcpng", .xcpng),
            ("FreeBSD", "", "pfsense", .pfsense),
            ("FreeBSD", "", "opnsense", .opnsense),
            ("Linux", "NAME=\"Alpine Linux\"\nID=alpine\n", "docker", .docker),
            ("Linux", "NAME=\"Debian GNU/Linux\"\nID=debian\n", "raspbian", .raspbian), // Raspberry Pi OS 64-bit
        ]
        for (uname, osRelease, marker, expected) in cases {
            XCTAssertEqual(detect(posix(uname, osRelease, markers: [marker])), expected, marker)
        }
    }

    func testMarkerPrecedence() {
        // Docker only when no other marker matched.
        XCTAssertEqual(detect(posix("Linux", "ID=debian\n", markers: ["casaos", "docker"])), .casaos)
        XCTAssertEqual(detect(posix("Linux", "ID=debian\n", markers: ["docker", "proxmox"])), .proxmox)
        // Appliances on Raspberry Pi OS show the appliance.
        XCTAssertEqual(detect(posix("Linux", "ID=debian\n", markers: ["raspbian", "openmediavault"])), .openmediavault)
        XCTAssertEqual(detect(posix("Linux", "ID=debian\n", markers: ["raspbian", "umbrel"])), .umbrel)
        // TrueNAS reported twice (/etc/version and midclt) is still TrueNAS.
        XCTAssertEqual(detect(posix("FreeBSD", "", markers: ["truenas", "truenas"])), .truenas)
        // Unknown markers are ignored.
        XCTAssertEqual(detect(posix("Linux", "ID=debian\n", markers: ["plan9"])), .debian)
    }

    func testMarkersMustBeWholeLines() {
        let ubuntu = posix("Linux", "NAME=\"Ubuntu\"\nID=ubuntu\nPRETTY_NAME=\"Ubuntu 24.04 (synology backup box)\"\nHOME_URL=\"https://synology.example\"\n")
        XCTAssertEqual(detect(ubuntu), .ubuntu)
        XCTAssertEqual(detect("TR_OS_ENV=%OS%\nLinux\nunique=\"synology_x\"\n"), .linux)
        XCTAssertEqual(detect("TR_OS_ENV=%OS%\nLinux\nDESCRIPTION=\"TR_OS=proxmox\"\n"), .linux)
    }

    // MARK: uname

    func testUname() {
        XCTAssertEqual(detect(posix("Darwin")), .macos)
        XCTAssertEqual(detect(posix("FreeBSD")), .freebsd)
        XCTAssertEqual(detect(posix("OpenBSD")), .openbsd)
        XCTAssertEqual(detect(posix("NetBSD")), .netbsd)
        XCTAssertEqual(detect(posix("VMkernel")), .vmware)
        XCTAssertEqual(detect(posix("Linux")), .linux)
        XCTAssertEqual(detect(posix("Linux", "ID=weirdos\n")), .linux)
        XCTAssertNil(detect(posix("SunOS")))
    }

    func testCRLFOutput() {
        XCTAssertEqual(detect("TR_OS_ENV=%OS%\r\nLinux\r\nTR_OS=synology\r\n"), .synology)
        XCTAssertEqual(detect("TR_OS_ENV=%OS%\r\nLinux\r\nID=\"rocky\"\r\n"), .rocky)
    }

    /// Output of the probe from before the catalog (uname first, no outer echo) still parses.
    func testOldProbeOutputShape() {
        XCTAssertEqual(detect("Linux\nID=ubuntu\n"), .ubuntu)
        XCTAssertEqual(detect("Darwin\n"), .macos)
        XCTAssertEqual(detect("Linux\nTR_OS_MARKER=synology\n"), .synology)
    }

    // MARK: Windows

    private let cmdEcho = "TR_OS_ENV=Windows_NT; sh -c \"uname -s; cat /etc/os-release 2>/dev/null; [ -e /etc/synoinfo.conf ] && echo TR_OS=synology; true\"\r\n"

    private func regQuery(_ installationType: String) -> String {
        "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\r\n    InstallationType    REG_SZ    \(installationType)\r\n\r\n"
    }

    func testCmdNeedsTheVersionFollowUp() {
        XCTAssertEqual(OSDetector.followUpCommand(forProbeOutput: cmdEcho), OSDetector.windowsVersionCommand)
        XCTAssertEqual(detect(cmdEcho), .windows, "without the version it is the current Windows")
        XCTAssertNil(OSDetector.followUpCommand(forProbeOutput: posix("Linux", "ID=debian\n")))
        XCTAssertNil(OSDetector.followUpCommand(forProbeOutput: posix("MINGW64_NT-10.0-22631")))
        XCTAssertNil(OSDetector.followUpCommand(forProbeOutput: ""))
    }

    func testWindowsVersionCommandIsReadOnlyCmd() {
        XCTAssertEqual(OSDetector.windowsVersionCommand,
                       "ver & reg query \"HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\" /v InstallationType")
    }

    func testWindowsBuildDecides11Or10() {
        let win11 = cmdEcho + "\r\nMicrosoft Windows [Version 10.0.22631.4317]\r\n" + regQuery("Client")
        XCTAssertEqual(detect(win11), .windows)
        let win10 = cmdEcho + "\r\nMicrosoft Windows [Version 10.0.19045.5011]\r\n" + regQuery("Client")
        XCTAssertEqual(detect(win10), .windows10)
        XCTAssertEqual(detect(cmdEcho + "Microsoft Windows [Version 10.0.22000.194]\r\n"), .windows, "22000 is Windows 11")
        XCTAssertEqual(detect(cmdEcho + "Microsoft Windows [Version 10.0.21996.1]\r\n"), .windows10)
        // Localized `ver` keeps the bracketed version.
        XCTAssertEqual(detect(cmdEcho + "Microsoft Windows [versão 10.0.19045.4529]\r\n"), .windows10)
    }

    func testWindowsServerIsWindowsWhateverTheBuild() {
        let server2022 = cmdEcho + "Microsoft Windows [Version 10.0.20348.2700]\r\n" + regQuery("Server")
        XCTAssertEqual(detect(server2022), .windows)
        let core2019 = cmdEcho + "Microsoft Windows [Version 10.0.17763.6414]\r\n" + regQuery("Server Core")
        XCTAssertEqual(detect(core2019), .windows)
    }

    func testWindowsWithAPosixLayerReadsTheBuildFromUname() {
        XCTAssertEqual(detect(posix("MINGW64_NT-10.0-22631")), .windows)   // Git for Windows sh
        XCTAssertEqual(detect(posix("MINGW64_NT-10.0-19045")), .windows10)
        XCTAssertEqual(detect(posix("MSYS_NT-10.0-19045")), .windows10)
        XCTAssertEqual(detect(posix("CYGWIN_NT-10.0-26100")), .windows)
        XCTAssertEqual(detect(posix("MINGW64_NT-10.0")), .windows, "no build: the current Windows")
    }

    func testWindowsVerOutputAlone() {
        XCTAssertEqual(detect("\r\nMicrosoft Windows [Version 10.0.22631.4317]\r\n"), .windows)
        XCTAssertEqual(detect("\r\nMicrosoft Windows [Version 10.0.19045.4317]\r\n"), .windows10)
    }

    // MARK: No false positives

    func testDevicesWithoutAPosixShellAreNotDetected() {
        let outputs = [
            "",
            "\n\n",
            // MikroTik RouterOS
            "bad command name TR_OS_ENV=%OS% (line 1 column 1)\n",
            // Cisco IOS
            "                      ^\n% Invalid input detected at '^' marker.\n",
            // PowerShell as the default shell, no sh on PATH
            "TR_OS_ENV=%OS%\r\nsh : The term 'sh' is not recognized as the name of a cmdlet, function, script file, or operable program.\r\n",
            // FortiOS
            "Unknown action 0\nCommand fail. Return code -1\n",
            // Sophos console menu text
            "Sophos Firewall\nMain Menu\n",
        ]
        for output in outputs {
            XCTAssertNil(detect(output), output)
        }
    }

    // MARK: Probe command

    func testProbeCommandShape() {
        let probe = OSDetector.probeCommand
        XCTAssertTrue(probe.hasPrefix("echo TR_OS_ENV=%OS%; sh -c \""), probe)
        XCTAssertTrue(probe.hasSuffix("\""), probe)
        let inner = String(probe.dropFirst("echo TR_OS_ENV=%OS%; sh -c \"".count).dropLast())
        // Nothing that cmd.exe, csh or the inner double quotes would expand or end.
        for character in ["\"", "$", "`", "%", "!", "\\", "\n", "*", "?"] {
            XCTAssertFalse(inner.contains(character), "inner script contains \(character)")
        }
        XCTAssertFalse(probe.contains("sudo"))
        XCTAssertLessThan(probe.count, 850)
        for check in [
            "[ -e /etc/synoinfo.conf ] && echo TR_OS=synology",
            "[ -e /etc/unraid-version ] && echo TR_OS=unraid",
            "grep -qs TrueNAS /etc/version && echo TR_OS=truenas",
            "command -v midclt >/dev/null 2>&1 && echo TR_OS=truenas",
            "[ -e /etc/config/uLinux.conf ] && echo TR_OS=qnap",
            "[ -e /etc/openmediavault ] && echo TR_OS=openmediavault",
            "[ -e /etc/casaos ] && echo TR_OS=casaos",
            "command -v casaos >/dev/null 2>&1 && echo TR_OS=casaos",
            "[ -e /home/umbrel/umbrel ] && echo TR_OS=umbrel",
            "[ -e /usr/bin/pveversion ] && echo TR_OS=proxmox",
            "[ -e /etc/xcp-ng-release ] && echo TR_OS=xcpng",
            "grep -qs pfSense /etc/platform && echo TR_OS=pfsense",
            "[ -e /usr/local/opnsense ] && echo TR_OS=opnsense",
            "[ -e /etc/rpi-issue ] && echo TR_OS=raspbian",
            "[ -e /.dockerenv ] && echo TR_OS=docker",
        ] {
            XCTAssertTrue(probe.contains(check), check)
        }
        XCTAssertTrue(inner.hasPrefix("uname -s; cat /etc/os-release 2>/dev/null; "), inner)
        XCTAssertTrue(inner.hasSuffix("; true"), inner)
    }

    /// Runs the real probe through the local /bin/sh: silent on stderr, exit 0, and detected.
    func testProbeRunsQuietlyInALocalShell() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", OSDetector.probeCommand]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(errors, "")
        XCTAssertTrue(output.hasPrefix("TR_OS_ENV=%OS%\n"), output)
        let detected = try XCTUnwrap(detect(output), output)
        #if os(macOS)
        XCTAssertEqual(detected, .macos)
        #else
        XCTAssertTrue(OSCatalog.shared.contains(detected), detected.rawValue)
        #endif
    }

    func testEveryDetectableIDIsInTheCatalog() {
        for badge in OSDetector.detectableBadges {
            XCTAssertTrue(OSCatalog.shared.contains(badge), badge.rawValue)
        }
        // Manual only: no POSIX shell, or not distinguishable from a probe.
        for manual: OSBadge in [.apple, .mikrotik, .ubiquiti, .cisco, .sophos, .fortinet, .asustor, .terramaster] {
            XCTAssertFalse(OSDetector.detectableBadges.contains(manual), manual.rawValue)
        }
    }
}

import XCTest
import CoreModels
@testable import AppCore

final class OSDetectorTests: XCTestCase {
    private func linux(_ osRelease: String) -> String { "Linux\n" + osRelease }

    func testDetectsUbuntuDebianRaspbianFedoraAlpineArchRHEL() {
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n")), .ubuntu)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=debian\n")), .debian)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=raspbian\nID_LIKE=debian\n")), .raspberryPiOS)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=fedora\n")), .fedora)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=\"rocky\"\nID_LIKE=\"rhel centos fedora\"\n")), .rhel)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=centos\n")), .rhel)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=almalinux\n")), .rhel)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=alpine\n")), .alpine)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=arch\n")), .arch)
        // ID_LIKE fallback when ID is unknown
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=pop\nID_LIKE=\"ubuntu debian\"\n")), .ubuntu)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=mint\nID_LIKE=debian\n")), .debian)
    }

    func testDetectsMacOSAndFreeBSD() {
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Darwin\n"), .macOS)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "FreeBSD\n"), .freeBSD)
    }

    func testDetectsSynologyAndHomeAssistant() {
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\nPRETTY_NAME=\"Debian\"\nID=debian\nTR_OS_MARKER=synology\n"), .synology)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=\"haos\"\nNAME=\"Home Assistant OS\"\n")), .homeAssistant)
    }

    func testUnknownLinuxFallsBackToLinux() {
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\n"), .linux)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=weirdos\n")), .linux)
        XCTAssertNil(OSDetector.badge(fromProbeOutput: ""))
        XCTAssertNil(OSDetector.badge(fromProbeOutput: "SunOS\n"))
    }

    // DSM 7.4: no /etc/os-release, synoinfo.conf exists but its first line is `AppleTalk="eth0"`.
    func testSynologyDetectedFromProbeMarker() {
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\nTR_OS_MARKER=synology\n"), .synology)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\r\nTR_OS_MARKER=synology\r\n"), .synology)
    }

    func testProbeCommandEmitsSynologyMarkerWhenSynoinfoExists() {
        XCTAssertTrue(OSDetector.probeCommand.contains("[ -e /etc/synoinfo.conf ] && echo TR_OS_MARKER=synology"))
        XCTAssertFalse(OSDetector.probeCommand.contains("cat /etc/synoinfo.conf"))
    }

    func testMentionOfSynologyElsewhereIsNotSynology() {
        let ubuntu = linux("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\nPRETTY_NAME=\"Ubuntu 24.04 (synology backup box)\"\nHOME_URL=\"https://synology.example\"\n")
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: ubuntu), .ubuntu)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\nunique=\"synology_x\"\n"), .linux)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\nupnpmodelname=\"DS918+\"\n"), .linux)
    }
}

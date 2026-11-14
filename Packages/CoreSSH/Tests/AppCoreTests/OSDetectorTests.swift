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
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\nPRETTY_NAME=\"Debian\"\nID=debian\nupnpmodelname=\"DS918+\"\nunique=\"synology_apollolake_918+\"\n"), .synology)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\nunique=\"synology_x\"\nID=debian\n"), .synology)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=\"haos\"\nNAME=\"Home Assistant OS\"\n")), .homeAssistant)
    }

    func testUnknownLinuxFallsBackToLinux() {
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: "Linux\n"), .linux)
        XCTAssertEqual(OSDetector.badge(fromProbeOutput: linux("ID=weirdos\n")), .linux)
        XCTAssertNil(OSDetector.badge(fromProbeOutput: ""))
        XCTAssertNil(OSDetector.badge(fromProbeOutput: "SunOS\n"))
    }
}

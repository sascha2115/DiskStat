import XCTest
@testable import diskstat

/// The `diskutil info -plist` parsing. Uncovered until a bug here showed up on
/// a real card, and it fails quietly: a volume labelled "Unknown" or with a
/// missing device looks the same as one that was never asked.
final class DiskMetaTests: XCTestCase {
    /// The device is what the row now shows, and what macOS quotes when it
    /// refuses to eject a busy disk.
    ///
    /// `DeviceNode` is deliberately absent here. It holds the same value with a
    /// `/dev/` prefix, and a dictionary carrying both keys passes whether the
    /// parser reads the right one or falls through to the fallback — which is
    /// exactly how this test got through a mutation that removed the
    /// `DeviceIdentifier` lookup entirely.
    func testParsesDeviceIdentifier() {
        let meta = DiskutilInspector.parse([
            "FileSystemPersonality": "exfat",
            "PartitionMapType": "GUID_partition_scheme",
            "DeviceIdentifier": "disk4s2"
        ])

        XCTAssertEqual(meta.deviceIdentifier, "disk4s2",
                       "the bare form, with no /dev/ prefix")
        XCTAssertEqual(meta.fileSystem, "exfat")
        XCTAssertEqual(meta.partitionMap, "GUID")
    }

    /// Both keys present, as on a real volume: the bare form wins, so the row
    /// never shows a `/dev/` path.
    func testPrefersTheBareFormWhenBothKeysArePresent() {
        let meta = DiskutilInspector.parse([
            "FileSystemPersonality": "exfat",
            "DeviceIdentifier": "disk4s2",
            "DeviceNode": "/dev/disk4s2"
        ])
        XCTAssertEqual(meta.deviceIdentifier, "disk4s2")
    }

    /// An APFS volume on a container: the identifier is several levels deep, and
    /// is exactly the shape shown in `diskutil list` output.
    func testParsesNestedAPFSDeviceIdentifier() {
        let meta = DiskutilInspector.parse([
            "FileSystemPersonality": "apfs",
            "DeviceIdentifier": "disk3s3s1"
        ])
        XCTAssertEqual(meta.deviceIdentifier, "disk3s3s1")
    }

    /// `DeviceNode` is present on every volume, so it is the fallback when
    /// `DeviceIdentifier` is absent. The prefix is stripped rather than shown.
    func testFallsBackToDeviceNodeWhenIdentifierMissing() {
        let meta = DiskutilInspector.parse([
            "FileSystemPersonality": "msdos_format",
            "DeviceNode": "/dev/disk2s1"
        ])
        XCTAssertEqual(meta.deviceIdentifier, "disk2s1")
    }

    /// No device key at all: nil, not a placeholder. The row omits the segment
    /// entirely rather than reading "exFAT • GUID • Unknown".
    func testMissingDeviceKeyIsNil() {
        let meta = DiskutilInspector.parse(["FileSystemPersonality": "exfat"])
        XCTAssertNil(meta.deviceIdentifier)
    }

    /// An empty string is present but useless, and must be treated as absent
    /// rather than rendered as a blank segment.
    func testEmptyDeviceIdentifierIsTreatedAsAbsent() {
        let meta = DiskutilInspector.parse([
            "FileSystemPersonality": "exfat",
            "DeviceIdentifier": "",
            "DeviceNode": "/dev/disk5s2"
        ])
        XCTAssertEqual(meta.deviceIdentifier, "disk5s2",
                       "an empty DeviceIdentifier must fall through to DeviceNode")
    }

    /// The unknown placeholder the cache uses before `diskutil` answers.
    func testUnknownMetaHasNoDevice() {
        XCTAssertNil(DiskMeta.unknown.deviceIdentifier)
        XCTAssertEqual(DiskMeta.unknown.fileSystem, "Unknown")
    }

    /// Against a real volume, to confirm the key names above are the ones
    /// `diskutil` actually emits and not just the ones the test invented.
    func testMatchesTheRealBootVolume() throws {
        let meta = DiskutilInspector.meta(forMountPath: "/")
        let identifier = try XCTUnwrap(meta.deviceIdentifier,
                                       "diskutil should always report a device for /")

        // The shape diskutil uses: disk<N> with optional s<N> segments.
        XCTAssertTrue(identifier.hasPrefix("disk"), "got \(identifier)")
        XCTAssertNotNil(identifier.range(of: #"^disk\d+(s\d+)*$"#, options: .regularExpression),
                        "unexpected device identifier shape: \(identifier)")
    }
}

/// The text of the filesystem line on each row.
///
/// Separate from the parsing tests because this is the part the user reads, and
/// the row itself is an `NSView` that cannot be built in a test — so the string
/// is assembled by a function that can.
final class MetaLineTests: XCTestCase {
    private func disk(fileSystem: String = "exFAT",
                      partitionMap: String = "GUID",
                      device: String? = "disk4s2") -> DiskUsage {
        DiskUsage(
            name: "MEDIADISK",
            mountURL: URL(fileURLWithPath: "/Volumes/MEDIADISK"),
            totalBytes: 4_000_000_000_000,
            freeBytes: 2_000_000_000_000,
            isExternal: true,
            isEjectable: true,
            fileSystem: fileSystem,
            partitionMap: partitionMap,
            deviceIdentifier: device
        )
    }

    func testShowsFilesystemMapAndDevice() {
        XCTAssertEqual(DiskMenuRowView.metaLine(for: disk()),
                       "exFAT • GUID • disk4s2")
    }

    /// No device yet — `diskutil` has not answered. The line must not end in a
    /// dangling separator or carry a placeholder.
    func testOmitsTheDeviceEntirelyWhenUnknown() {
        XCTAssertEqual(DiskMenuRowView.metaLine(for: disk(device: nil)),
                       "exFAT • GUID")
        XCTAssertFalse(DiskMenuRowView.metaLine(for: disk(device: nil)).hasSuffix("•"))
    }

    /// A nested APFS identifier, the shape the boot volume reports.
    func testShowsNestedDeviceIdentifier() {
        XCTAssertEqual(
            DiskMenuRowView.metaLine(for: disk(fileSystem: "APFS",
                                               partitionMap: "APM",
                                               device: "disk3s3s1")),
            "APFS • APM • disk3s3s1"
        )
    }
}

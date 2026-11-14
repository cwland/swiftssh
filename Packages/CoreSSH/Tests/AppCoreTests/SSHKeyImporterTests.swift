import XCTest
import CoreModels
@testable import AppCore

// Throwaway fixture keys, generated once with Python `cryptography` (+ `bcrypt` for the OpenSSH
// passphrase-protected key). Never used anywhere else.
private enum Fixture {
    /// Passphrase-protected OpenSSH Ed25519 key: cipher aes256-ctr, kdf bcrypt.
    static let encryptedEd25519 = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAJ
nR32rXkdI/33IHG/cXE4AAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGHo
f0G3adf/YKXAhHppskcKx9yRqt5VHAWDx6igZ97bAAAAkPcULENNP9VJNmI2Nx79
01EgEPeB0Le0xDI/VsB5dhv94mwCXDziICIHpZkt/nDO/tWwAmiw9TDOEGh5jn8n
1f1G3pRMXxpWImPmkoISZVABrKmJpy0yKIekc6P/qwnR+LjwiT8wYfZ3FqJgmTnS
y98eXq4a5Nfno5J+5gCs6jvBsbMlPipfj2687XuFj7DhxQ==
-----END OPENSSH PRIVATE KEY-----
"""
    static let encryptedEd25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGHof0G3adf/YKXAhHppskcKx9yRqt5VHAWDx6igZ97b"

    /// Unencrypted OpenSSH ECDSA P-256 key.
    static let ecdsa = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNl
Y2RzYS1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQQr0MREpH3kO2B694WB
68w21WEKeBRfbqIfQ3pNI/CFYqv5AutB818oXziasPbtmhgrLicVl6+1FXo7EDae
GpqYAAAAoNUfj7LVH4+yAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAy
NTYAAABBBCvQxESkfeQ7YHr3hYHrzDbVYQp4FF9uoh9Dek0j8IViq/kC60HzXyhf
OJqw9u2aGCsuJxWXr7UVejsQNp4ampgAAAAhAOXr6ph0xyFl6yi46cXS/c9L3jx9
LUYwstmViYpkC9FYAAAAAAECAwQFBgc=
-----END OPENSSH PRIVATE KEY-----
"""
    static let ecdsaPublic = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCvQxESkfeQ7YHr3hYHrzDbVYQp4FF9uoh9Dek0j8IViq/kC60HzXyhfOJqw9u2aGCsuJxWXr7UVejsQNp4ampg="

    /// Traditional (PKCS#1) PEM RSA-2048 key encrypted with AES-256-CBC.
    static let encryptedPEMRSA = """
-----BEGIN RSA PRIVATE KEY-----
Proc-Type: 4,ENCRYPTED
DEK-Info: AES-256-CBC,16273B72B40E4DE9E51AEC3A67335362

96qK9XZJKGOptd7qLzPyNpbEdT/E4+5G3XAvSMDNNE4RPFWHYaM56IgOF3V9NMJh
bBlmpgrwRBURxjOOCVLPfddlK9CjrVbfIALQQQpwHJLXM0vRTU1x5BE62xbBYXrt
nW4Lcyc5a8WqAqBXmjtKOvqXLVnwxfmMpiC2Oinyfql8TqkNa4F888aVjLyPy2Lf
0fi6Mj6/dQNthK8xERqK9niK+F3hyXgz0LKy0foHabEbaiDeKPOG6IJqeMzizctn
ZLuj8GAkqcXfdfXXaGWa+74A5oMrF8X1qaUmrSWNEcZ+xTr4V3n35QjId6KZVd3r
lKJr9ildmjVHPhDpzSIxif1ZXkMn6OfYxzZIXvbCfSA8/YQGMUDbxJD3oRnX5hoZ
BvWpxfbojX6qydHvjTeKKOwyozBLTJu7xN/zX3D0XOSZCx62y6SGUu0s1YgxgHgW
TWuJeOH+bIuJjjEFt5ef2SSPSMliRp4f2caCu3Gbo1mosEhTL3q9bFYfXzPDuvhh
KZIGtJY1jUq72je0dsYwCSlkigChPHeCIyasTfV/9V0WUMKLyRD5e99Bjfk+sD0o
pzo9tQHomQscNM2tJ725IUpKNLL+2+Z79wxii8JKd5dnCSdFrIWpkG6JFc8cgjh6
apMQYKMoAxT/yLWMY+uHmcvqAogtyyNMeWyF0agZioOE/Wsi4V/ftHCbwr9JmTw1
QadsFuF3pT4YRdWnjI7twVhdGGNUpviDwZDSB2sDIxi0vQXjKemJeHGnLDtsCNu2
YI5+gEPhphrbbHy65lrQUuI8T/xK7ApWUm843iHIgfXKj7og8VgjpI/forpGm0f8
eJLRMTqlR/c0JLDdZamO98itIiUwTBQWXMc0xvGGEN/FAWX0FP4h3pqyRN4VqHPP
qjBeFCmWGD0PNdqqkoMSzLOLv6oMODI4oxLmya0iIkmIIXxgt6q16HCRVAr6/q7C
OLye9V+0/LrqFne58lqYYNEKTpzFd/U6pp+UKXs6f/a1+AV/PU0nzFbT1fkK8eo5
LyNbVgJBML5JprNLatEI3t0TR0WBoZi81BCPjrezd3Q7wKptenkr7UQ0AjE1+N/k
EoaOZrC5Zq/khbWvbQlddEaiOaGoGR0lHoKkEp7Q7gz8N1Ak5Pu9kZxHryqmVJ1T
QJ5s1vn3L1rBI01tvp7iL5zWXvpJ/USIfnxtLor9sQy2aYlKRmFGhKjW5A2BUTtz
bSn7UxkbfHSd/kCZjJWqR5UcOkmVhMlG+Z3V4fsLNZm7S3fh/2CFurwehENWnFuI
Bz4jl4TlYqPYxUhfnNxG9ioKZi/bukaBdOxO7zJbsqaccpswHEClMu6VYuVVYft5
O7mD0wjG/tDOG+dK5rgAvv2ImaZ+e8WvvGSJedwLcbfMqiM9GoHqfwWOqIsbAxo9
bggnonKI/lf3T6TFxfEHRh+xipRplFNE31qgO54uaNO5biZG/lbATfPnjvk43amT
PnyPhfbTGMX86d/r3sxYfTNAzN++9X4V2rnQIZrsxhlz2kVe2hIDpX6kLNX6ffHX
SXGJeAh2cI4WIf8gHczGwFIcVSys3pXmtl6//tg27/mfqs5/qBamL1us8TyVpyo/
-----END RSA PRIVATE KEY-----
"""

    /// Unencrypted PKCS#8 RSA-2048 key.
    static let pkcs8RSA = """
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDFwZrrw0TMfnEF
zDfEkJj6/aXGTvXpH7u+jOr4I99PLCeVKXlZzBGQmtZZEDFGGXIO9bcvGMKmtBJf
dSJtE9mu1Xov805W6ZsfK/WNnKa9oJKPnclB1+Ru3W3HQJgU/fvWosvUXyUOS1xB
yA7EtCOCPJfIl1mXzSo1W5GXabkp8f+jr+14k5c6oTvoC7Qggp1HJn++1nuvqyQY
103NC2NADKrS/FrivnkangSz2qPNMyaO5S+AXt6Wr0DSpjR/KSyb+nct4UfVrsu3
l+R1V92gkImuFlozRT9EESqh4SvowPfSeyeMNpIgqWxBDvwSe8craBZe1RVQgDX/
hjsWER0lAgMBAAECggEAA+QrTHwslc/fdk3+WJmWImA3MMexJTvI3wxuUODXKNDA
BvpzMcNnIr7ikguUcKJDtowlZTbvQ5uo/eRelPdjnJdaSWhtUElV/P8e3JZqczJI
7VcH6goEa8hjJofR8PMjehB82B+21AkYa7ny98dp/crRRh2boiCjyzt99KpcU06F
I7XIWGDkHlA/UTszvC4ZPOu7xDexn7/4d7fkSKREB78c63MtaTKC1RedXwjvoWaU
4Od1QuiRGEU8J5S+6Na4yWt43b+si3bG/Daz3cp1Mop9wrhc8BzO0tFCdqLVF4cY
FAtk4ctTrXGOUlzG2qVYK87fkUNvY3dT8fVW+gBusQKBgQDkcK4HHKFaKzuSCl4J
aOTD7nLmXHM/mwCK3K3M1jxX0TEflwNgx80xU2FzwltTKZXZuA+cHVOoPHJs1wab
V3noJluYueJ3XApiMOntmfPj6MXMkbGu4fLD+dsPLp3bucus3CKuxncOOZbYDcrL
CHdL9McVrxHJFpwLZSCrNVM09QKBgQDdnULFD0GpQlexJiYJ/oCiVnlUzrwAdH8l
pV6F511P0Y6BDEbjXgGJO/TkuDK9E5mr5aOzCxH2DMB1IT65tganmwFsgxMN2szn
DgMYIDoboYVdTXe+qTtEqD2gyhqF5IL+eVING4fe7wQzPhUVk64yfncskGWvVlGI
MfR9AD2pcQKBgCuHbSHdysEry8YgQ5r3aeAL58kNhMhx+MB9HIETsZvqOLoURIiE
ig0EHmW4ez51hiBeelr9G5vLKOKkdpXTLV+XL40Cnqyv1Sqwt2KXG2oqSMaaXIk+
dMvzKFLURzA/Txg5OkKjfrwvLRcuSZ42lsTad7UiDvmKXWGue3MkTh6hAoGBALMl
Vz5ZUOj0elL31bQqie2xHa/S1uM/STEzdy+jkijd6+ah+AQAkBlR4GusA0gZOhZd
MnGft0tBj6qfz0bswIBoq0P+yT5f61e0Wgf8tTx024xK/UuhHgooPnlmJv6pdMMl
a5Cw+qraaHjL7NteYGjtFoVtzOVqT8pbJ5qMwUvhAoGAShrS3ifVN++eJGz/qCuL
xSTkFPDIOZI3oN0wYiJ5p9UIa8o8dRpGmXrykYla1oRX/IOjyekHgIhX8msJ7gFZ
GMZNyF0B6lxSADh+WnZPuG9VdPaAAG9etx5CWkiQbpxo95ssrZaTBqdLdGgoucCP
cW9zEj/C2g4IhHtB5RlE/RE=
-----END PRIVATE KEY-----
"""
    static let pkcs8RSAPublic = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDFwZrrw0TMfnEFzDfEkJj6/aXGTvXpH7u+jOr4I99PLCeVKXlZzBGQmtZZEDFGGXIO9bcvGMKmtBJfdSJtE9mu1Xov805W6ZsfK/WNnKa9oJKPnclB1+Ru3W3HQJgU/fvWosvUXyUOS1xByA7EtCOCPJfIl1mXzSo1W5GXabkp8f+jr+14k5c6oTvoC7Qggp1HJn++1nuvqyQY103NC2NADKrS/FrivnkangSz2qPNMyaO5S+AXt6Wr0DSpjR/KSyb+nct4UfVrsu3l+R1V92gkImuFlozRT9EESqh4SvowPfSeyeMNpIgqWxBDvwSe8craBZe1RVQgDX/hjsWER0l"

    /// Encrypted PKCS#8 (PBES2) key. Only the first lines of the body are kept: the importer looks
    /// at the label and never parses the ciphertext.
    static let encryptedPKCS8 = """
-----BEGIN ENCRYPTED PRIVATE KEY-----
MIIFNTBfBgkqhkiG9w0BBQ0wUjAxBgkqhkiG9w0BBQwwJAQQDIQOTQmGm5Y//TjB
DrqCSwICCAAwDAYIKoZIhvcNAgkFADAdBglghkgBZQMEASoEEFVUtGFpcA/B3bCY
m335/ZoEggTQpwVN4rOqnr5iTTfufqpFczlqEawTpgpk10pP9q3HeS36UW6PprUF
-----END ENCRYPTED PRIVATE KEY-----
"""

    /// Unencrypted PKCS#8 Ed25519 key.
    static let pkcs8Ed25519 = """
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEII4RNN3TTjbR1zkplF5ue2quLbMqyyUa1sJNNjXYkVDf
-----END PRIVATE KEY-----
"""
    static let pkcs8Ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILNFfRT3Bxr4XS1xMwwPIduSckOYfEC6H6eB/kkicSn7"

    /// SEC1 EC key (`BEGIN EC PRIVATE KEY`), the same P-256 key as `ecdsa`.
    static let sec1EC = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIOXr6ph0xyFl6yi46cXS/c9L3jx9LUYwstmViYpkC9FYoAoGCCqGSM49
AwEHoUQDQgAEK9DERKR95DtgeveFgevMNtVhCngUX26iH0N6TSPwhWKr+QLrQfNf
KF84mrD27ZoYKy4nFZevtRV6OxA2nhqamA==
-----END EC PRIVATE KEY-----
"""

    /// Unencrypted OpenSSH RSA-2048 key (no comment).
    static let openSSHRSA = """
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdz
c2gtcnNhAAAAAwEAAQAAAQEAwCJZ4Ai0Ww9HBnKtEywzb8u6jvlZ1fFjDXPmUsyB
yLH/oUUd5Ylue59qRyJNobcBrDazkczm81kZHlfrEJHXEjpLQpLMb8EwUSlFKeJB
B33joFuQF18w51kKrH7nk+JhmKUG4C3DAGcDi70ylLrxLyJxqPML/uXsvlYH+LsS
XASEMa0dSAIWfcYkVVB3Dz/DiAVzTWJCLyqplcn3gjR3jhcXGYVOVOpPSmcHCC2B
yEGvgUrTH7QsFBCHtgB9sDbGNnwT8q5LGxL0TbEMAu/xkhB85RMtrEYBG6/O0vYm
0dq8b2DMeeLaGVN8FxLxfpl1GaCF8pCiwcIqel7hZChpTwAAA7gDipjRA4qY0QAA
AAdzc2gtcnNhAAABAQDAIlngCLRbD0cGcq0TLDNvy7qO+VnV8WMNc+ZSzIHIsf+h
RR3liW57n2pHIk2htwGsNrORzObzWRkeV+sQkdcSOktCksxvwTBRKUUp4kEHfeOg
W5AXXzDnWQqsfueT4mGYpQbgLcMAZwOLvTKUuvEvInGo8wv+5ey+Vgf4uxJcBIQx
rR1IAhZ9xiRVUHcPP8OIBXNNYkIvKqmVyfeCNHeOFxcZhU5U6k9KZwcILYHIQa+B
StMftCwUEIe2AH2wNsY2fBPyrksbEvRNsQwC7/GSEHzlEy2sRgEbr87S9ibR2rxv
YMx54toZU3wXEvF+mXUZoIXykKLBwip6XuFkKGlPAAAAAwEAAQAAAQAttT5aXNfD
PfwwnYFtKTvHYdktAEcN7ZIZ9jOaCQrrGuVskUvOeoZtJHydFZ0QVsAwHwdTLULY
K58dJ99FHtziejnDSbcW8weylzXcA/ZieOF5Ga9K0BuLPhSa+snO1bFQJhpfpKNa
aidezBDHbz3Hb9NIVSHKbxqGIWNeGesBNquQtKyjzHrrje62ajy6bh6/7FJvczwg
2q+RtOMyIUg9f8IckO36wlXU9cuhss86rJ2TdytZKOGEhj8aQtkXRwothiOr/jUW
HanOZBMc+/paSmlQOfb9Y3JDY3ADu4vA7E0xfHj1b0Y28YOG+hZws9oUSxH/f7ku
OqLXB4ziYdmxAAAAgAsZLgfXaZ1sK7TKamhKSPOGYt+fOF5tUP/+kADI8VyylR8i
gipDQhgekNz9e6ihcYLUjK91CSkaMu9lGqHlpZjRapsLtpAlHJXN+ipQYeRzZue7
+o356TrCiTOG1Fgu/ddCs+2zgerAR0/mUON/dCrDptRLL5ioKbak4VZeREgHAAAA
gQD5+kKdr3STW407OxGe57g92VTcqi6uO/LlMourJOB/p5LB4cdwvgB4o6PNUfCO
Ok9Eg7hnu+9s/YaUf2PO7oySz79ZMd5xwwfI2RpXBuSEw93We5CAwdDyyAMt7+il
VPuSDyWzyoDuYDjgvRvLwuw3iQzxpbOMfIvocIgpz5wweQAAAIEAxMNXTE8v/XXI
5AofRFEOr7uLlsGVWRFE3PYo2xFx0DeyMxebihV4tphikbaoYwlYALAXZ+t1GYE8
9s0Is8dkp9+lm3iumQXEuvq5MlC8cMqB3YXQQU/Cg3fJRjbh+Big3f6rmNvosx7k
8H7/jCV7DIh2cid/NElR5CfpzFoyRgcAAAAAAQID
-----END OPENSSH PRIVATE KEY-----
"""
    static let openSSHRSAPublic = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAIlngCLRbD0cGcq0TLDNvy7qO+VnV8WMNc+ZSzIHIsf+hRR3liW57n2pHIk2htwGsNrORzObzWRkeV+sQkdcSOktCksxvwTBRKUUp4kEHfeOgW5AXXzDnWQqsfueT4mGYpQbgLcMAZwOLvTKUuvEvInGo8wv+5ey+Vgf4uxJcBIQxrR1IAhZ9xiRVUHcPP8OIBXNNYkIvKqmVyfeCNHeOFxcZhU5U6k9KZwcILYHIQa+BStMftCwUEIe2AH2wNsY2fBPyrksbEvRNsQwC7/GSEHzlEy2sRgEbr87S9ibR2rxvYMx54toZU3wXEvF+mXUZoIXykKLBwip6XuFkKGlP"
}

private func pemBody(_ pem: String) throws -> (label: String, body: [UInt8]) {
    let lines = pem.split(separator: "\n").map(String.init)
    let label = String(lines[0].dropFirst("-----BEGIN ".count).dropLast("-----".count))
    let base64 = lines.dropFirst().dropLast().filter { !$0.contains(":") }.joined()
    return (label, try XCTUnwrap(Data(base64Encoded: base64)).map { $0 })
}

private func armor(_ label: String, _ body: [UInt8]) -> String {
    OpenSSHFormat.pem(label: label, body: body, lineLength: 70)
}

/// An `openssh-key-v1` container with the given fields; the private section is passed through as is.
private func openSSHKey(cipher: String = "none", publicBlob: [UInt8], privateSection: [UInt8], keyCount: UInt32 = 1) -> String {
    var body = Array("openssh-key-v1\0".utf8)
    body += OpenSSHFormat.string(cipher)
    body += OpenSSHFormat.string(cipher == "none" ? "none" : "bcrypt")
    body += OpenSSHFormat.string(cipher == "none" ? [] : OpenSSHFormat.string([UInt8](repeating: 7, count: 16)) + OpenSSHFormat.uint32(16))
    body += OpenSSHFormat.uint32(keyCount)
    body += OpenSSHFormat.string(publicBlob)
    body += OpenSSHFormat.string(privateSection)
    return armor("OPENSSH PRIVATE KEY", body)
}

private func ed25519Blob(_ publicBytes: [UInt8]) -> [UInt8] {
    OpenSSHFormat.string("ssh-ed25519") + OpenSSHFormat.string(publicBytes)
}

private func withoutComment(_ line: String) -> String {
    line.split(separator: " ").prefix(2).joined(separator: " ")
}

private func assertImportError(
    _ expected: SSHKeyImportError, _ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(error as? SSHKeyImportError, expected, file: file, line: line)
    }
}

final class SSHKeyImporterTests: XCTestCase {
    func testInspectsGeneratedEd25519() throws {
        let key = SSHKeyGenerator.ed25519(comment: "cory@mac-mini")
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: key.privateKey),
            ImportedKey(keyType: .ed25519, publicKey: key.publicKey, isEncrypted: false)
        )

        let bare = SSHKeyGenerator.ed25519(comment: "")
        XCTAssertEqual(try SSHKeyImporter.inspect(privateKey: bare.privateKey).publicKey, bare.publicKey)
    }

    func testInspectsGeneratedRSA() throws {
        let key = try SSHKeyGenerator.rsa4096(comment: "cory@mac-mini")
        // PKCS#1 has no comment field, so the derived line has none.
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: key.privateKey),
            ImportedKey(keyType: .rsa, publicKey: withoutComment(key.publicKey), isEncrypted: false)
        )
    }

    func testInspectsOpenSSHRSAAndPKCS8Keys() throws {
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: Fixture.openSSHRSA),
            ImportedKey(keyType: .rsa, publicKey: Fixture.openSSHRSAPublic, isEncrypted: false)
        )
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: Fixture.pkcs8RSA),
            ImportedKey(keyType: .rsa, publicKey: Fixture.pkcs8RSAPublic, isEncrypted: false)
        )
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: Fixture.pkcs8Ed25519),
            ImportedKey(keyType: .ed25519, publicKey: Fixture.pkcs8Ed25519Public, isEncrypted: false)
        )
    }

    func testEncryptedOpenSSHKeyStillYieldsPublicKey() throws {
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: Fixture.encryptedEd25519),
            ImportedKey(keyType: .ed25519, publicKey: Fixture.encryptedEd25519Public, isEncrypted: true)
        )
    }

    func testEncryptedPEMHasNoPublicKey() throws {
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: Fixture.encryptedPEMRSA),
            ImportedKey(keyType: .rsa, publicKey: nil, isEncrypted: true)
        )
        assertImportError(.encryptedPKCS8Unsupported) { try SSHKeyImporter.inspect(privateKey: Fixture.encryptedPKCS8) }
    }

    func testRejectsGarbageAndUnsupportedTypes() throws {
        assertImportError(.unrecognizedFormat) { try SSHKeyImporter.inspect(privateKey: "hello") }
        assertImportError(.unrecognizedFormat) { try SSHKeyImporter.inspect(privateKey: "") }
        assertImportError(.unrecognizedFormat) { try SSHKeyImporter.inspect(privateKey: Fixture.pkcs8RSAPublic) }
        assertImportError(.unrecognizedFormat) {
            try SSHKeyImporter.inspect(privateKey: "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n")
        }
        assertImportError(.unrecognizedFormat) { // no END line
            try SSHKeyImporter.inspect(privateKey: String(Fixture.pkcs8RSA.split(separator: "\n").dropLast().joined(separator: "\n")))
        }
        assertImportError(.unsupportedKeyType("ecdsa-sha2-nistp256")) { try SSHKeyImporter.inspect(privateKey: Fixture.ecdsa) }
        assertImportError(.unsupportedKeyType("ecdsa")) { try SSHKeyImporter.inspect(privateKey: Fixture.sec1EC) }
        assertImportError(.unsupportedKeyType("dsa")) {
            try SSHKeyImporter.inspect(privateKey: "-----BEGIN DSA PRIVATE KEY-----\nAAAA\n-----END DSA PRIVATE KEY-----\n")
        }
        let skBlob = OpenSSHFormat.string("sk-ssh-ed25519@openssh.com") + OpenSSHFormat.string([UInt8](repeating: 1, count: 32))
        assertImportError(.unsupportedKeyType("sk-ssh-ed25519@openssh.com")) {
            try SSHKeyImporter.inspect(privateKey: openSSHKey(cipher: "aes256-ctr", publicBlob: skBlob, privateSection: [1, 2, 3]))
        }
        // PKCS#8 wrapping an EC key reports the algorithm, not a format error.
        let (_, sec1) = try pemBody(Fixture.sec1EC)
        let ecAlgorithm: [UInt8] = [0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                                    0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        var pkcs8Contents: [UInt8] = [0x02, 0x01, 0x00] + ecAlgorithm + [0x04, UInt8(sec1.count)] + sec1
        pkcs8Contents = [0x30, 0x81, UInt8(pkcs8Contents.count)] + pkcs8Contents
        assertImportError(.unsupportedKeyType("ecdsa")) { try SSHKeyImporter.inspect(privateKey: armor("PRIVATE KEY", pkcs8Contents)) }
    }

    func testRejectsInconsistentOpenSSHKeys() throws {
        let publicBytes = [UInt8](repeating: 9, count: 32)
        func section(check2: UInt32 = 42, type: String = "ssh-ed25519", embeddedPublic: [UInt8] = publicBytes) -> [UInt8] {
            var bytes = OpenSSHFormat.uint32(42) + OpenSSHFormat.uint32(check2) + OpenSSHFormat.string(type)
            bytes += OpenSSHFormat.string(embeddedPublic) + OpenSSHFormat.string([UInt8](repeating: 3, count: 32) + embeddedPublic)
            bytes += OpenSSHFormat.string("c") + [1, 2, 3, 4, 5]
            return bytes
        }
        let blob = ed25519Blob(publicBytes)
        // The well-formed baseline is accepted…
        XCTAssertEqual(
            try SSHKeyImporter.inspect(privateKey: openSSHKey(publicBlob: blob, privateSection: section())).publicKey,
            "ssh-ed25519 \(Data(blob).base64EncodedString()) c"
        )
        // …and each inconsistency is rejected.
        for bad in [
            openSSHKey(publicBlob: blob, privateSection: section(check2: 43)),
            openSSHKey(publicBlob: blob, privateSection: section(type: "ssh-rsa")),
            openSSHKey(publicBlob: blob, privateSection: section(embeddedPublic: [UInt8](repeating: 8, count: 32))),
            openSSHKey(publicBlob: blob, privateSection: section(), keyCount: 2),
            openSSHKey(publicBlob: blob, privateSection: section() + [UInt8](repeating: 0, count: 8)), // over-long padding
            openSSHKey(publicBlob: ed25519Blob([1, 2, 3]), privateSection: section()),
            openSSHKey(publicBlob: blob + [0], privateSection: section()),
        ] {
            assertImportError(.unrecognizedFormat) { try SSHKeyImporter.inspect(privateKey: bad) }
        }
        // An algorithm "name" that is not a short identifier is treated as garbage, never echoed.
        let junkName = String(repeating: "A", count: 200)
        assertImportError(.unrecognizedFormat) {
            try SSHKeyImporter.inspect(privateKey: openSSHKey(
                publicBlob: OpenSSHFormat.string(junkName) + OpenSSHFormat.string(publicBytes), privateSection: section()
            ))
        }
    }

    func testMalformedInputThrowsInsteadOfCrashing() throws {
        let generated = SSHKeyGenerator.ed25519(comment: "fuzz")
        let pems = [generated.privateKey, Fixture.encryptedEd25519, Fixture.openSSHRSA, Fixture.pkcs8RSA, Fixture.pkcs8Ed25519]
        for pem in pems {
            let (label, body) = try pemBody(pem)
            // Every strict prefix is truncated somewhere and must throw.
            for length in 0..<body.count {
                XCTAssertThrowsError(try SSHKeyImporter.inspect(privateKey: armor(label, Array(body.prefix(length)))), "\(label) prefix \(length)")
            }
            // Corrupting any single byte may or may not be detected, but must never crash.
            for index in body.indices {
                for value: UInt8 in [0x00, 0xFF] {
                    var corrupted = body
                    corrupted[index] = value
                    _ = try? SSHKeyImporter.inspect(privateKey: armor(label, corrupted))
                }
            }
        }
        assertImportError(.unrecognizedFormat) {
            try SSHKeyImporter.inspect(privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n!!!not base64!!!\n-----END OPENSSH PRIVATE KEY-----")
        }
    }

    func testParsesPublicKeyLine() throws {
        let generated = SSHKeyGenerator.ed25519(comment: "cory@mac-mini")
        var parsed = try SSHKeyImporter.parsePublicKey(generated.publicKey)
        XCTAssertEqual(parsed.0, .ed25519)
        XCTAssertEqual(parsed.1, generated.publicKey)

        parsed = try SSHKeyImporter.parsePublicKey(Fixture.openSSHRSAPublic + "  work laptop  ")
        XCTAssertEqual(parsed.0, .rsa)
        XCTAssertEqual(parsed.1, Fixture.openSSHRSAPublic + " work laptop")

        parsed = try SSHKeyImporter.parsePublicKey(Fixture.pkcs8Ed25519Public)
        XCTAssertEqual(parsed.0, .ed25519)
        XCTAssertEqual(parsed.1, Fixture.pkcs8Ed25519Public)
    }

    func testRejectsBadPublicKeyLines() throws {
        assertImportError(.unsupportedKeyType("ecdsa-sha2-nistp256")) { try SSHKeyImporter.parsePublicKey(Fixture.ecdsaPublic) }
        let rsaBase64 = Fixture.openSSHRSAPublic.split(separator: " ")[1]
        for bad in [
            "", "hello", "ssh-ed25519", "ssh-ed25519 !!!", "ssh-ed25519 \(rsaBase64)", // name disagrees with the blob
            "ssh-rsa \(rsaBase64.dropLast(8))", // truncated blob (still valid base64)
            "\(Fixture.pkcs8Ed25519Public)\n\(Fixture.openSSHRSAPublic)", // two keys
            Fixture.pkcs8RSA,
        ] {
            assertImportError(.unrecognizedFormat) { try SSHKeyImporter.parsePublicKey(bad) }
        }
    }

    func testToleratesCRLFAndSurroundingWhitespace() throws {
        func messUp(_ text: String) -> String {
            "  \r\n\t" + text.split(separator: "\n").map { " \($0)\t" }.joined(separator: "\r\n") + "\r\n\r\n  "
        }
        let generated = SSHKeyGenerator.ed25519(comment: "cory@mac-mini")
        XCTAssertEqual(try SSHKeyImporter.inspect(privateKey: messUp(generated.privateKey)).publicKey, generated.publicKey)
        XCTAssertEqual(try SSHKeyImporter.inspect(privateKey: messUp(Fixture.encryptedPEMRSA)).isEncrypted, true)
        XCTAssertEqual(try SSHKeyImporter.inspect(privateKey: messUp(Fixture.pkcs8RSA)).publicKey, Fixture.pkcs8RSAPublic)

        let parsed = try SSHKeyImporter.parsePublicKey("\r\n  " + generated.publicKey.replacingOccurrences(of: " ", with: " \t ") + " \r\n")
        XCTAssertEqual(parsed.1, generated.publicKey)
    }

    func testErrorsNeverEchoKeyMaterial() throws {
        let inputs = [
            Fixture.ecdsa, Fixture.sec1EC, Fixture.encryptedPKCS8, Fixture.ecdsaPublic,
            String(Fixture.pkcs8RSA.dropLast(40)), Fixture.pkcs8RSA.replacingOccurrences(of: "PRIVATE KEY", with: "SECRET"),
        ]
        var errors: [Error] = []
        for input in inputs {
            do { _ = try SSHKeyImporter.inspect(privateKey: input) } catch { errors.append(error) }
            do { _ = try SSHKeyImporter.parsePublicKey(input) } catch { errors.append(error) }
        }
        XCTAssertEqual(errors.count, inputs.count * 2)
        let fragments = inputs.flatMap { $0.split(whereSeparator: { $0 == "\n" || $0 == " " }) }
            .filter { $0.count >= 16 && !$0.hasPrefix("-----") && !$0.hasPrefix("ecdsa-") }
        XCTAssertFalse(fragments.isEmpty)
        for error in errors {
            for text in [String(describing: error), error.localizedDescription] {
                XCTAssertFalse(text.isEmpty)
                for fragment in fragments { XCTAssertFalse(text.contains(fragment), text) }
            }
        }
    }

    // MARK: normalizePastedKey

    func testNormalizePastedKeyRestoresSmartDashedArmorLines() {
        let smart = "\u{2014}\u{2014}-BEGIN OPENSSH PRIVATE KEY\u{2014}\u{2014}-\nAAAA\u{2013}BBBB\n\u{2013}\u{2013}\u{2013}END OPENSSH PRIVATE KEY\u{2014}--\n"
        XCTAssertEqual(
            SSHKeyImporter.normalizePastedKey(smart),
            "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\u{2013}BBBB\n-----END OPENSSH PRIVATE KEY-----\n"
        )
    }

    func testNormalizePastedKeyLeavesCleanTextUnchanged() {
        let clean = "-----BEGIN RSA PRIVATE KEY-----\r\nProc-Type: 4,ENCRYPTED\r\nabc\r\n-----END RSA PRIVATE KEY-----"
        XCTAssertEqual(SSHKeyImporter.normalizePastedKey(clean), clean)
        XCTAssertEqual(SSHKeyImporter.normalizePastedKey(""), "")
        XCTAssertEqual(SSHKeyImporter.normalizePastedKey("--not armor\u{2014}"), "--not armor\u{2014}")
    }

    func testNormalizePastedKeyMakesSmartDashedKeyImportable() throws {
        let generated = SSHKeyGenerator.ed25519(comment: "c")
        let smart = generated.privateKey
            .replacingOccurrences(of: "-----BEGIN", with: "\u{2014}\u{2014}-BEGIN")
            .replacingOccurrences(of: "KEY-----", with: "KEY\u{2014}\u{2014}-")
        XCTAssertThrowsError(try SSHKeyImporter.inspect(privateKey: smart))
        let inspected = try SSHKeyImporter.inspect(privateKey: SSHKeyImporter.normalizePastedKey(smart))
        XCTAssertEqual(inspected.keyType, .ed25519)
    }
}

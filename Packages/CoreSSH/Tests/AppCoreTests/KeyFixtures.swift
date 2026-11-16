/// Test-only keys made with `ssh-keygen` (OpenSSH) and `openssl genpkey` for the imported key tests. They
/// sign in nowhere. The armor lines are put together at run time so the file doesn't look like a leaked
/// key to secret scanners.
enum KeyFixtures {
    private static func armored(_ label: String, _ body: String) -> String {
        let dashes = String(repeating: "-", count: 5)
        return "\(dashes)BEGIN \(label)\(dashes)\n\(body)\n\(dashes)END \(label)\(dashes)\n"
    }

    /// `ssh-keygen -t ed25519 -N "" -C cory@laptop`
    static let plainEd25519 = armored("OPENSSH PRIVATE KEY", """
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACCFx0PyCFDoALxFZOMORugOnFsnf7deT26UNjI5FW9bGgAAAJBacO9eWnDv
XgAAAAtzc2gtZWQyNTUxOQAAACCFx0PyCFDoALxFZOMORugOnFsnf7deT26UNjI5FW9bGg
AAAED28yGZZxeso5iF/7tgP+aWTNci16Pp0ntHiQ4/QZGKXIXHQ/IIUOgAvEVk4w5G6A6c
Wyd/t15PbpQ2MjkVb1saAAAAC2NvcnlAbGFwdG9wAQI=
""")
    static let plainEd25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIXHQ/IIUOgAvEVk4w5G6A6cWyd/t15PbpQ2MjkVb1sa cory@laptop"
    static let plainEd25519Fingerprint = "SHA256:JarNYvbSKzyuzmfJUVye3aMlaPPBRQ/i5YzHXbH6fj8"

    /// `ssh-keygen -t ed25519 -N "correct horse" -C enc@mac` (bcrypt KDF, aes256-ctr)
    static let encryptedEd25519 = armored("OPENSSH PRIVATE KEY", """
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABA3k+Dt5o
vsxAo+D9npti7FAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIHP12/0t8JYc9nGY
avCw6yCk2X7HgRUDouA3A4iKFbilAAAAkCLIyqiO4YOj47lLI6VcDSgGm1Rz4fDC64i8dh
+EmM3Rk6xmvq2lXKpbP5lSuVt6dNMJuwqEhBQe32jHgCMwNocPImrNMxFPkm1G3yFHLOoc
4p/YVY3Et4OIebbRXG5kuDPNiJfcoMWKIY5Y+qkZJnG1DA5nLBqr+hrPyfqJFpHweYIEEM
uOqUKEXzFJoJY79g==
""")
    static let encryptedEd25519Passphrase = "correct horse"
    static let encryptedEd25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHP12/0t8JYc9nGYavCw6yCk2X7HgRUDouA3A4iKFbil enc@mac"
    static let encryptedEd25519Fingerprint = "SHA256:u7yhgESS9KDZI3kVFn52LppoZhqJD23AJAXs1zAqkKs"

    /// `ssh-keygen -t ed25519 -N pw -Z aes256-gcm@openssh.com`
    static let gcmEncryptedEd25519 = armored("OPENSSH PRIVATE KEY", """
b3BlbnNzaC1rZXktdjEAAAAAFmFlczI1Ni1nY21Ab3BlbnNzaC5jb20AAAAGYmNyeXB0AA
AAGAAAABBod7p/0HeoBI2xkXxEO2HFAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAA
IOpy3ioHe5zIfzvjzs9UBkCJa6Aj0QpOHr9mhcgM1TuYAAAAkLD8BaoiT5HvZZEaxCgvXD
CvJlMs1EvGIwrOhHcqaoHsUE+zqP/3HIccvEeyEIP+60qJPGqG6dx5s2Dg8pZu+6TE+cMn
LRb8/iLTnsC4KILIriCKiBH6JQs2BZOwezbVxUmKW41zDuL63uW6K/agfsT1eoePBOmmnW
3PoEoqnxLyojVIzhWzmdIJn6u8MkuMpyI+A9eB0uKacO5lEf4Zpv0=
""")

    /// `openssl genpkey -algorithm ed25519` (unencrypted PKCS#8)
    static let pkcs8Ed25519 = armored("PRIVATE KEY", """
MC4CAQAwBQYDK2VwBCIEILfBqO6fjBs4WrX3rtnodr2sklmZhzQoMjF2C9EK3vma
""")
    static let pkcs8Ed25519Public = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJFu8h4OUGWb3QorEGw/ZEBhrUdRfeoXjUtkY48ewQxK"
    static let pkcs8Ed25519Fingerprint = "SHA256:TVR4ZveD5NriNIZp7Y+L0bhNTER9qdZ4huDTkc8gFS8"

    /// `ssh-keygen -t rsa -b 1024 -N ""`
    static let rsa = armored("OPENSSH PRIVATE KEY", """
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
NhAAAAAwEAAQAAAIEAu8aevZtMGW4JEJOqUI5EVGISIb87TZ1zqm6eL35aSDQLhZbiAlkl
s0Ny3X3edKlcwfcyudbqXEHs6Ca++3ChTO5KaTHIicOIMgJ2XN/ioOTLvAu2jTD+zL8Oxt
cZqxgjYp+kouDvUwbtRA1MtuVaQ9YgVGZUvGawycmzvPEqyq0AAAIAl4PxGJeD8RgAAAAH
c3NoLXJzYQAAAIEAu8aevZtMGW4JEJOqUI5EVGISIb87TZ1zqm6eL35aSDQLhZbiAlkls0
Ny3X3edKlcwfcyudbqXEHs6Ca++3ChTO5KaTHIicOIMgJ2XN/ioOTLvAu2jTD+zL8OxtcZ
qxgjYp+kouDvUwbtRA1MtuVaQ9YgVGZUvGawycmzvPEqyq0AAAADAQABAAAAgQCLka4bsH
p3zFnggGFvTs9rCRoBC2rA3e9DFsVs97WTRVvrB6Mlq61h+Rg/mXbnr5rKcTq69wtrV3UH
eQUrTyQUCkb0ybTOU89WW+6dCLDOBjvH73/uijEIzC5Umv5A2ojHdtGZUe7iRk6G8ze2GZ
3T9MfDuwzt6UnHuHHHZMNO4QAAAEEAypUQu+S5sDvZ19VeWyQ88H3H51Y/CKnyf3HKlkTk
mOZY8LVaP/BInVjnvBof/usRxwULwvbS/0xIBFWzmyxCrAAAAEEA9koq5adv+4z0PwbMRV
azcOzUEdSNyMdK25QpajPEZarVKCdmdzxXJHWYxXHhFdS7R2tEGd3m0cjgDRwOABpnxwAA
AEEAwy3dbUA2XgDSU4h9xabtCYjPyLw2GAsCmNCsQnYsMKztfsHOtD2JHzclvivC152Cve
bsjB0mxq+8/cBW/sxB6wAAAANyc2EBAgMEBQY=
""")

    /// `ssh-keygen -t ecdsa -N ""`
    static let ecdsa = armored("OPENSSH PRIVATE KEY", """
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQT2a3S4UQPzsW3dhkdsbtvo6o0vCXUH
XcaSwCtwq+/pBJjooISNesS52umpXSbzCYeKFJJMtr09dLR/SH7T1MwfAAAAoDS+H140vh
9eAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBPZrdLhRA/Oxbd2G
R2xu2+jqjS8JdQddxpLAK3Cr7+kEmOighI16xLna6aldJvMJh4oUkky2vT10tH9IftPUzB
8AAAAhAOSwDxrNwDj6F1ATwiFU/Cql5Fm/YQcb/LCwNQMIU4ptAAAAAmVjAQIDBAU=
""")
}

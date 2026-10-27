# Third-party components

cTerm is built with the following open-source packages. Their licenses apply to
the corresponding code and are included transitively in the application.

| Package | Use | License |
| --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | SSH client / channel / PTY API | MIT |
| [swift-nio-ssh](https://github.com/Joannis/swift-nio-ssh) (Citadel fork) | SSH protocol implementation | Apache-2.0 |
| [swift-nio](https://github.com/apple/swift-nio) | Event loops and networking | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | Cryptographic primitives | Apache-2.0 |
| [swift-log](https://github.com/apple/swift-log) | Logging | Apache-2.0 |
| [BigInt](https://github.com/attaswift/BigInt) | RSA key arithmetic | MIT |
| [ColorizeSwift](https://github.com/mtynior/ColorizeSwift) | Terminal coloring helpers | MIT |

The packaged application additionally links Apple system frameworks and uses
the OpenSSH `ssh-keygen` binary that ships with macOS solely to unlock encrypted
private keys. No OpenSSH networking code is used for the SSH transport.

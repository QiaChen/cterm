import AppKit

let arguments = CommandLine.arguments
#if DEBUG
if arguments.contains("--ui-ssh") {
    MainActor.assumeIsolated {
        UISmokeRunner.run()
    }
}
if let keyIndex = arguments.firstIndex(of: "--key-check"), keyIndex + 1 < arguments.count {
    let passphrase = keyIndex + 2 < arguments.count ? arguments[keyIndex + 2] : nil
    KeyCheck.run(path: arguments[keyIndex + 1], passphrase: passphrase)
}
if let index = arguments.firstIndex(of: "--pty-check"), index + 2 < arguments.count {
    PtyCheck.run(keys: arguments[index + 1], command: Array(arguments[(index + 2)...]))
}
if arguments.contains("--ssh-smoke") {
    MainActor.assumeIsolated {
        SSHSmokeTest.run()
    }
}
if arguments.contains("--ai-smoke") {
    MainActor.assumeIsolated {
        AISmokeTest.run()
    }
}
if arguments.contains("--sftp-smoke") {
    MainActor.assumeIsolated {
        SFTPSmokeTest.run()
    }
}
if let snapshotIndex = arguments.firstIndex(of: "--snapshot"),
   snapshotIndex + 1 < arguments.count {
    MainActor.assumeIsolated {
        SnapshotRunner.run(outputPath: arguments[snapshotIndex + 1])
    }
}
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

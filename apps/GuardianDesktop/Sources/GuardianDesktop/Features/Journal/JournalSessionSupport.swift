import Foundation

enum GuardianSSHCommandResolution {
    case command(String)
    case unavailable(String)
}

struct GuardianTerminalSSHIdentity {
    let privateKeyURL: URL
    let publicKeyURL: URL
    let knownHostsURL: URL
    let publicKey: String

    static func ensurePresent() throws -> GuardianTerminalSSHIdentity {
        let root = storageDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let privateKeyURL = root.appendingPathComponent("guardian-terminal-ed25519")
        let publicKeyURL = root.appendingPathComponent("guardian-terminal-ed25519.pub")
        let knownHostsURL = root.appendingPathComponent("known_hosts")

        if !FileManager.default.fileExists(atPath: privateKeyURL.path) ||
            !FileManager.default.fileExists(atPath: publicKeyURL.path)
        {
            try generateKeyPair(privateKeyURL: privateKeyURL)
        }

        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: Data())
        }

        let publicKey = try String(contentsOf: publicKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GuardianTerminalSSHIdentity(
            privateKeyURL: privateKeyURL,
            publicKeyURL: publicKeyURL,
            knownHostsURL: knownHostsURL,
            publicKey: publicKey
        )
    }

    private static var storageDirectory: URL {
        GuardianAppSupportPaths.storageDirectory.appendingPathComponent("ssh", isDirectory: true)
    }

    private static func generateKeyPair(privateKeyURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = [
            "-q",
            "-t", "ed25519",
            "-N", "",
            "-C", "guardian-desktop",
            "-f", privateKeyURL.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "ssh-keygen failed"
            throw NSError(
                domain: "GuardianTerminalSSHIdentity",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorOutput]
            )
        }
    }
}

func guardianSSHLaunchCommand(baseCommand: String) -> String {
    "\(baseCommand) -tt"
}

func guardianSSHCommandResolution(vmAccess: GuardianVMAccess?) -> GuardianSSHCommandResolution {
    guard let vmAccess else {
        return .unavailable("Guardian is still loading your VM access. Try opening the entry again in a moment.")
    }

    let vmLabel = vmAccess.vmDisplayName ?? vmAccess.vmID ?? "your Guardian VM"

    switch vmAccess.accessState {
    case "unassigned":
        return .unavailable("No Guardian VM is assigned to this account yet. Ask an operator to assign one in the backend.")
    case "needs_ssh_key":
        return .unavailable("Guardian is still registering your terminal SSH key. Refresh state and try again in a moment.")
    case "provisioning":
        return .unavailable("Guardian found \(vmLabel), but its runtime workspace is still provisioning.")
    case "error":
        return .unavailable(vmAccess.bootstrapError ?? "Guardian could not finish provisioning \(vmLabel).")
    default:
        break
    }

    guard let linuxUser = vmAccess.linuxUser, !linuxUser.isEmpty else {
        return .unavailable("Guardian found \(vmLabel), but your Linux user is not provisioned yet.")
    }

    guard let sshHost = vmAccess.sshHost, !sshHost.isEmpty else {
        return .unavailable("Guardian found \(vmLabel), but its SSH host is missing from backend VM access.")
    }

    guard vmAccess.canConnect else {
        return .unavailable("Guardian found \(vmLabel), but it is not ready for SSH connections yet.")
    }

    do {
        let identity = try GuardianTerminalSSHIdentity.ensurePresent()
        let sshPort = vmAccess.sshPort ?? 22
        return .command([
            "/usr/bin/ssh",
            "-p \(shellQuoted(String(sshPort)))",
            "-i \(shellQuoted(identity.privateKeyURL.path))",
            "-o BatchMode=yes",
            "-o IdentitiesOnly=yes",
            "-o ControlMaster=no",
            "-o ControlPath=none",
            "-o ServerAliveInterval=30",
            "-o ServerAliveCountMax=3",
            "-o StrictHostKeyChecking=accept-new",
            "-o UserKnownHostsFile=\(shellQuoted(identity.knownHostsURL.path))",
            shellQuoted("\(linuxUser)@\(sshHost)"),
        ].joined(separator: " "))
    } catch {
        NSLog("guardianSSHBaseCommand identity error: %@", String(describing: error))
        return .unavailable("Guardian could not prepare a local SSH key for VM access: \(error.localizedDescription)")
    }
}

func shellQuoted(_ value: String) -> String {
    guard !value.isEmpty else {
        return "''"
    }

    let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
    return "'\(escaped)'"
}

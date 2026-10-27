import Foundation

/// What a terminal session needs from the other end: bytes in, bytes out and
/// a window size. Implemented by an SSH channel and by a local shell.
@MainActor
protocol TerminalConnection: AnyObject {
    var state: SSHSessionState { get }
    var onStateChange: ((SSHSessionState) -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    /// Called once when the session ends, with a message for the user.
    var onEnd: ((String?) -> Void)? { get set }

    func connect()
    func send(_ data: Data)
    func resize(cols: Int, rows: Int)
    /// Ends the session on the user's request.
    func disconnect()
}

extension SSHConnection: TerminalConnection {}

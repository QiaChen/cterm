import NIOCore
import NIOPosix
import XCTest
@testable import cTerm

final class KeepAliveTests: XCTestCase {
    func testHandlerTurnsOnTCPKeepAlive() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let server = try ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }

        let client = try ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(TCPKeepAliveHandler()) }
            .connect(to: server.localAddress!).wait()
        defer { try? client.close().wait() }

        let tcp = SocketOptionLevel(IPPROTO_TCP)
        XCTAssertNotEqual(try client.getOption(ChannelOptions.socketOption(.so_keepalive)).wait(), 0)
        XCTAssertEqual(try client.getOption(ChannelOptions.socket(tcp, TCP_KEEPALIVE)).wait(),
                       TCPKeepAliveHandler.idle)
        XCTAssertEqual(try client.getOption(ChannelOptions.socket(tcp, TCP_KEEPINTVL)).wait(),
                       TCPKeepAliveHandler.interval)
        XCTAssertEqual(try client.getOption(ChannelOptions.socket(tcp, TCP_KEEPCNT)).wait(),
                       TCPKeepAliveHandler.count)
    }
}

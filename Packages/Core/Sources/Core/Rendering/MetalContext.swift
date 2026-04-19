import Metal
import MetalKit
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "MetalContext")

public final class MetalContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    public enum Error: Swift.Error {
        case noDevice
        case noCommandQueue
        case libraryLoadFailed(Swift.Error?)
    }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw Error.noDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw Error.noCommandQueue
        }
        self.device = device
        self.commandQueue = queue

        do {
            self.library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            log.error("Failed to load Metal library from bundle: \(error.localizedDescription)")
            throw Error.libraryLoadFailed(error)
        }
        log.info("Metal ready — device: \(device.name, privacy: .public)")
    }
}

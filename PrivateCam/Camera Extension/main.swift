import Foundation
import CoreMediaIO

let providerSource = PrivateCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()

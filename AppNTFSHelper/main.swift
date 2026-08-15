import Foundation

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: helperMachServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.main.run()

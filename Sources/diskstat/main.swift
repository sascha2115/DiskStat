import AppKit
import Darwin
import UserNotifications

let app = NSApplication.shared
let delegate = DiskMenuController()
app.delegate = delegate
app.run()

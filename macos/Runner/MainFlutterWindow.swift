import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var fujiUsb: FujiUsb?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    fujiUsb = FujiUsb(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

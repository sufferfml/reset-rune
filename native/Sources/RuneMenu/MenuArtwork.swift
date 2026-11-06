// INPUT: Packaged images, or checkout assets when running a debug build from source.
// OUTPUT: Native tray and panel images. See native/README.md.
import AppKit

enum MenuArtwork {
    static func panel(_ filename: String) -> NSImage? {
        // A panel owns its image for the lifetime of the open view.
        if let url = Bundle.main.url(forResource: filename, withExtension: nil),
           let image = NSImage(contentsOf: url) { return image }
        #if DEBUG
        return NSImage(contentsOf: sourceAssets.appendingPathComponent("panel/\(filename)"))
        #else
        return nil
        #endif
    }

    static func tray(_ name: String) -> NSImage? {
        if let image = Bundle.main.image(forResource: name) { return image }
        #if DEBUG
        let icons = sourceAssets.appendingPathComponent("icons")
        guard let image = NSImage(contentsOf: icons.appendingPathComponent("\(name).png")) else { return nil }
        if let data = try? Data(contentsOf: icons.appendingPathComponent("\(name)@2x.png")),
           let retina = NSBitmapImageRep(data: data) {
            retina.size = image.size
            image.addRepresentation(retina)
        }
        return image
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static let sourceAssets = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // RuneMenu
        .deletingLastPathComponent() // Sources
        .deletingLastPathComponent() // native
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("assets")
    #endif
}

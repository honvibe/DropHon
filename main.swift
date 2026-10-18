// DropHon — file shelf for macOS. Personal project, not on the App Store.
// Drag files + shake the cursor → floating shelf + instant share tiles.
import AppKit
import Quartz
import QuickLookThumbnailing

// MARK: - Shake detection (pure, covered by --selftest)

/// Shake rule:
/// a stroke counts only after travelling `minTravel`; pausing > `idleReset` or the
/// session passing `sessionLength` resets the count; shake = count > `needed`.
/// Sensitivity presets: low (4, 20pt) · medium (3, 12pt) · high (1, 5pt).
struct ShakeDetector {
    var needed = 4
    var minTravel: CGFloat = 20
    var idleReset: TimeInterval = 0.2
    var sessionLength: TimeInterval = 1.0
    private var lastX: CGFloat?
    private var lastT: TimeInterval = 0
    private var sessionStart: TimeInterval = 0
    private var movingLeft: Bool?
    private var travel: CGFloat = 0
    private var count = 0

    mutating func reset() { lastX = nil; movingLeft = nil; travel = 0; count = 0 }

    mutating func feed(x: CGFloat, t: TimeInterval) -> Bool {
        defer { lastX = x; lastT = t }
        guard let last = lastX, x != last else {
            if lastX == nil { sessionStart = t }
            return false
        }
        if t - sessionStart > sessionLength { travel = 0; count = 0; sessionStart = t }
        if t - lastT > idleReset { travel = 0; count = 0 }
        let left = x < last
        if left == movingLeft || movingLeft == nil {
            travel += abs(x - last)
        } else {
            if travel >= minTravel { count += 1 }
            travel = 0
        }
        movingLeft = left
        if count > needed { reset(); return true }
        return false
    }
}

func selfTest() {
    func run(_ xs: [CGFloat], dt: TimeInterval) -> Bool {
        var s = ShakeDetector(); var hit = false
        for (i, x) in xs.enumerated() where s.feed(x: x, t: Double(i) * dt) { hit = true }
        return hit
    }
    func zig(_ strokes: Int) -> [CGFloat] {
        (0..<strokes).flatMap { i -> [CGFloat] in
            let up = stride(from: 0, through: 60, by: 10).map { CGFloat($0) }
            return i % 2 == 0 ? up : up.reversed()
        }
    }
    precondition(run(zig(7), dt: 0.01), "fast zigzag (6 direction changes) should shake")
    precondition(!run(zig(5), dt: 0.01), "4 direction changes is not enough (needs > 4)")
    precondition(!run(zig(7), dt: 0.25), "pauses longer than 0.2s reset the count")
    precondition(!run(stride(from: 0, through: 600, by: 10).map { CGFloat($0) }, dt: 0.01), "straight drag should not shake")
    precondition(!run((0..<40).map { CGFloat($0 % 2 * 5) }, dt: 0.01), "small jitter should not shake")
    print("selftest ok")
}

// MARK: - Shared look

func readFileURLs(_ pb: NSPasteboard) -> [URL] {
    pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

/// Rounded frosted card used by both the shelf and the share panel.
func makeCard(size: NSSize, radius: CGFloat = 24) -> NSVisualEffectView {
    let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    fx.material = .popover
    fx.state = .active
    // maskImage (not layer.cornerRadius) so the window shadow follows the rounded shape too
    let r = radius
    let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
        NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
    }
    mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    mask.resizingMode = .stretch
    fx.maskImage = mask
    return fx
}

func makePanel(size: NSSize, at origin: NSPoint) -> NSPanel {
    let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = .floating
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = true
    p.isReleasedWhenClosed = false
    return p
}

func appIcon(_ bundleID: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
}

// MARK: - Shelf

/// Borderless panels can't take keyboard focus by default; the grid needs it (space / delete).
final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

/// Collapsed shelf: file stack + "N Files ›" pill (click pill → grid). Drag the stack = all files.
final class ShelfView: NSView, NSDraggingSource {
    var urls: [URL] = [] { didSet { refresh() } }
    var onDrop: (([URL]) -> Void)?
    var onDeliveredAll: (() -> Void)?
    var onExpand: (() -> Void)?
    private let icon = NSImageView()
    private let pill = NSView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false { didSet { needsDisplay = true } }

    init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        registerForDraggedTypes([.fileURL])
        icon.frame = NSRect(x: (size.width - 100) / 2, y: 58, width: 100, height: 100)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.unregisterDraggedTypes() // otherwise NSImageView swallows drops
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 11
        pill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        pill.addSubview(label)
        addSubview(icon); addSubview(pill)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        if urls.isEmpty {
            let cfg = NSImage.SymbolConfiguration(pointSize: 44, weight: .light)
            icon.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            icon.contentTintColor = .tertiaryLabelColor
            label.stringValue = "Drop files here"
        } else {
            icon.image = NSWorkspace.shared.icon(forFiles: urls.map(\.path))
            icon.contentTintColor = nil
            makeStack(Array(urls.prefix(3)))
            label.stringValue = (urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Files") + "  ›"
        }
        // pill hugs its text
        label.sizeToFit()
        let w = min(bounds.width - 32, label.frame.width + 20)
        pill.frame = NSRect(x: (bounds.width - w) / 2, y: 18, width: w, height: 22)
        label.frame = NSRect(x: 10, y: 3, width: w - 20, height: 16)
    }

    /// Up to 3 real thumbnails fanned out in a stack; keeps the file icon until they load.
    private func makeStack(_ files: [URL]) {
        let want = files
        var thumbs = [NSImage?](repeating: nil, count: files.count)
        let group = DispatchGroup()
        for (i, u) in files.enumerated() {
            group.enter()
            let req = QLThumbnailGenerator.Request(fileAt: u, size: NSSize(width: 90, height: 90),
                                                   scale: 2, representationTypes: .all)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                DispatchQueue.main.async { thumbs[i] = rep?.nsImage; group.leave() }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self, Array(self.urls.prefix(3)) == want else { return } // files changed meanwhile
            let imgs = thumbs.enumerated().map { $1 ?? NSWorkspace.shared.icon(forFile: want[$0].path) }
            let angles: [CGFloat] = imgs.count == 1 ? [0] : imgs.count == 2 ? [-8, 6] : [-10, 8, 0]
            self.icon.image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
                for (img, a) in zip(imgs, angles) {
                    NSGraphicsContext.saveGraphicsState()
                    let t = NSAffineTransform()
                    t.translateX(by: 50, yBy: 50); t.rotate(byDegrees: a); t.concat()
                    let sz = img.size, k = 76 / max(sz.width, sz.height)
                    let r = NSRect(x: -sz.width * k / 2, y: -sz.height * k / 2, width: sz.width * k, height: sz.height * k)
                    let shadow = NSShadow(); shadow.shadowBlurRadius = 4; shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.set()
                    img.draw(in: r)
                    NSGraphicsContext.restoreGraphicsState()
                }
                return true
            }
        }
    }

    override func draw(_ r: NSRect) {
        guard hovering else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 18, yRadius: 18)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); path.fill()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Drop in
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard (s.draggingSource as? ShelfView) !== self else { return [] }
        hovering = true; return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hovering = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        hovering = false
        let new = readFileURLs(s.draggingPasteboard)
        onDrop?(new)
        return !new.isEmpty
    }

    // Click pill → grid. Drag stack → all files. Empty shelf → drag moves the window.
    override func mouseDown(with e: NSEvent) { if urls.isEmpty { window?.performDrag(with: e) } }
    override func mouseUp(with e: NSEvent) {
        if !urls.isEmpty, pill.frame.contains(convert(e.locationInWindow, from: nil)) { onExpand?() }
    }
    override func mouseDragged(with e: NSEvent) {
        guard !urls.isEmpty else { return }
        let items = urls.map { u -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: u as NSURL)
            item.setDraggingFrame(icon.frame, contents: NSWorkspace.shared.icon(forFile: u.path))
            return item
        }
        beginDraggingSession(with: items, event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic] // destination decides, same as a normal Finder drag
    }
    func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
        if operation != [] { onDeliveredAll?() } // shelf goes away once delivered
    }
}

/// One file in the expanded grid. Selected = rounded box (8pt radius);
/// a drag hovering over it dims the icon to 0.7.
final class ShelfItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfItem")
    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 96))
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        let iv = NSImageView(frame: NSRect(x: 14, y: 36, width: 56, height: 56))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.unregisterDraggedTypes()
        let tf = NSTextField(wrappingLabelWithString: "")
        tf.frame = NSRect(x: 2, y: 2, width: 80, height: 30)
        tf.font = .systemFont(ofSize: 11)
        tf.alignment = .center
        tf.maximumNumberOfLines = 2
        tf.lineBreakMode = .byTruncatingMiddle
        v.addSubview(iv); v.addSubview(tf)
        view = v; imageView = iv; textField = tf
    }
    override var representedObject: Any? {
        didSet {
            guard let u = representedObject as? URL else { return }
            imageView?.image = NSWorkspace.shared.icon(forFile: u.path)
            textField?.stringValue = u.lastPathComponent
            // real preview (photo, PDF page…); falls back to the file icon
            let req = QLThumbnailGenerator.Request(fileAt: u, size: NSSize(width: 56, height: 56),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
                guard let rep else { return }
                DispatchQueue.main.async {
                    guard (self?.representedObject as? URL) == u else { return } // cell reused meanwhile
                    self?.imageView?.image = rep.nsImage
                }
            }
        }
    }
    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil }
    }
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { imageView?.alphaValue = highlightState == .forSelection ? 0.7 : 1 }
    }
}

/// Grid keyboard: space = Quick Look, delete = remove from shelf .
final class ShelfGrid: NSCollectionView, QLPreviewPanelDataSource {
    var onDelete: ((Set<IndexPath>) -> Void)?
    var selectedURLs: [URL] {
        selectionIndexPaths.sorted().compactMap { (item(at: $0)?.representedObject) as? URL }
    }
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 49: // space
            guard let ql = QLPreviewPanel.shared(), !selectedURLs.isEmpty else { return }
            if ql.isVisible { ql.orderOut(nil) } else { NSApp.activate(ignoringOtherApps: true); ql.makeKeyAndOrderFront(nil) }
        case 51, 117: // delete, forward delete
            if !selectionIndexPaths.isEmpty { onDelete?(selectionIndexPaths) }
        default: super.keyDown(with: e)
        }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt i: Int) -> QLPreviewItem! { selectedURLs[i] as NSURL }
}

final class Shelf: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static var open: [Shelf] = []
    static let collapsedSize = NSSize(width: 180, height: 190)
    static let expandedSize = NSSize(width: 300, height: 330)
    let panel: NSPanel
    private let stack = ShelfView(size: Shelf.collapsedSize)
    private let grid = ShelfGrid()
    private let gridTitle = NSTextField(labelWithString: "")
    private var urls: [URL] = [] { didSet { urlsChanged() } }
    private func urlsChanged() { stack.urls = urls; grid.reloadData(); gridTitle.stringValue = "\(urls.count) Files" }
    private var dragging: Set<IndexPath> = []

    init(at p: NSPoint, urls: [URL] = []) {
        panel = KeyPanel(contentRect: NSRect(origin: NSPoint(x: p.x - Shelf.collapsedSize.width / 2,
                                                             y: p.y - Shelf.collapsedSize.height / 2),
                                             size: Shelf.collapsedSize),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configure(panel)
        stack.onDrop = { [weak self] in self?.add($0) }
        stack.onDeliveredAll = { [weak self] in self?.dismiss() }
        stack.onExpand = { [weak self] in self?.setExpanded(true) }
        grid.collectionViewLayout = {
            let l = NSCollectionViewFlowLayout()
            l.itemSize = NSSize(width: 84, height: 96)
            l.minimumInteritemSpacing = 4; l.minimumLineSpacing = 4
            l.sectionInset = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)
            return l
        }()
        grid.register(ShelfItem.self, forItemWithIdentifier: ShelfItem.id)
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.backgroundColors = [.clear]
        grid.dataSource = self; grid.delegate = self
        grid.registerForDraggedTypes([.fileURL])
        grid.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        grid.onDelete = { [weak self] ips in self?.remove(ips) }
        self.urls = urls
        urlsChanged() // didSet doesn't fire inside init
        setExpanded(false)
        Shelf.open.append(self)
        panel.orderFrontRegardless()
    }

    private func configure(_ p: NSPanel) {
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
    }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!
                            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!, target: self, action: action)
        b.isBordered = false
        b.contentTintColor = .tertiaryLabelColor
        return b
    }

    /// Swap between the stack and the grid, keeping the shelf's top-left corner in place.
    func setExpanded(_ expanded: Bool) {
        let size = expanded ? Shelf.expandedSize : Shelf.collapsedSize
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: false)
        let card = makeCard(size: size)
        let close = button("xmark.circle.fill", "Close", #selector(dismiss))
        close.frame = NSRect(x: 10, y: size.height - 30, width: 20, height: 20)
        if expanded {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - 40))
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.documentView = grid
            grid.frame = scroll.bounds
            card.addSubview(scroll)
            gridTitle.font = .systemFont(ofSize: 12, weight: .semibold)
            gridTitle.alignment = .center
            gridTitle.frame = NSRect(x: 40, y: size.height - 29, width: size.width - 80, height: 16)
            card.addSubview(gridTitle)
            let collapse = button("arrow.down.right.and.arrow.up.left.circle.fill", "Collapse", #selector(collapse))
            collapse.frame = NSRect(x: size.width - 30, y: size.height - 30, width: 20, height: 20)
            card.addSubview(collapse)
        } else {
            card.addSubview(stack)
        }
        card.addSubview(close)
        panel.contentView = card
        if expanded { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(grid) }
    }

    @objc private func collapse() { setExpanded(false) }
    @objc func dismiss() { panel.orderOut(nil); Shelf.open.removeAll { $0 === self } }

    private func add(_ new: [URL]) { urls += new.filter { !urls.contains($0) } }
    private func remove(_ ips: Set<IndexPath>) {
        let drop = Set(ips.map(\.item))
        urls = urls.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        if urls.isEmpty { dismiss() }
    }

    // Grid data
    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection s: Int) -> Int { urls.count }
    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: ShelfItem.id, for: ip)
        item.representedObject = urls[ip.item]
        return item
    }

    // Drag single items out; delivered items leave the shelf
    func collectionView(_ cv: NSCollectionView, canDragItemsAt ips: Set<IndexPath>, with e: NSEvent) -> Bool { true }
    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        urls[ip.item] as NSURL
    }
    func collectionView(_ cv: NSCollectionView, draggingSession s: NSDraggingSession, willBeginAt p: NSPoint,
                        forItemsAt ips: Set<IndexPath>) { dragging = ips }
    func collectionView(_ cv: NSCollectionView, draggingSession s: NSDraggingSession, endedAt p: NSPoint,
                        dragOperation op: NSDragOperation) {
        if op != [] { remove(dragging) }
        dragging = []
    }

    // Drop more files into the grid (but not its own items back)
    func collectionView(_ cv: NSCollectionView, validateDrop d: NSDraggingInfo,
                        proposedIndexPath p: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation op: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        (d.draggingSource as? NSCollectionView) === cv ? [] : .copy
    }
    func collectionView(_ cv: NSCollectionView, acceptDrop d: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation op: NSCollectionView.DropOperation) -> Bool {
        let new = readFileURLs(d.draggingPasteboard)
        add(new)
        return !new.isEmpty
    }
}

// MARK: - Instant share tiles (AirDrop / Messages / Mail / Copy)
// Layout:
// 4pt outer padding, equal cells, tile background inset 4pt, corner 16, 10% grey fill,
// accent fill + haptic on hover, list drag formation, title in a separate floating label.

/// black@10% in light mode, white@10% in dark
let tileFill = NSColor(name: nil) { a in
    NSColor(white: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0, alpha: 0.1)
}

final class ActionTile: NSView {
    let title: String
    let perform: ([URL]) -> Void
    var onDone: (() -> Void)?
    var onHover: ((ActionTile?) -> Void)?
    private let fill = CALayer()
    private var highlighted = false { didSet { restyle() } }

    init(frame: NSRect, title: String, icon: NSImage?, perform: @escaping ([URL]) -> Void) {
        self.title = title; self.perform = perform
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        fill.frame = bounds.insetBy(dx: 4, dy: 4)
        fill.cornerRadius = 16
        fill.cornerCurve = .continuous
        layer?.addSublayer(fill)
        let s: CGFloat = 34
        let iv = NSImageView(frame: NSRect(x: (frame.width - s) / 2, y: (frame.height - s) / 2, width: s, height: s))
        iv.image = icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.unregisterDraggedTypes()
        addSubview(iv)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.backgroundColor = (highlighted ? NSColor.controlAccentColor : tileFill).cgColor
        }
        if highlighted { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
    override func viewDidChangeEffectiveAppearance() { restyle() }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        s.draggingFormation = .list
        highlighted = true; onHover?(self); return .copy
    }
    override func draggingExited(_ s: NSDraggingInfo?) { highlighted = false; onHover?(nil) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        highlighted = false; onHover?(nil)
        let urls = readFileURLs(s.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        // let the drag finish before opening the share sheet
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true); self.perform(urls); self.onDone?() }
        return true
    }
}

final class InstantActions {
    static let shared = InstantActions()
    private static let side: CGFloat = 196   // 2×2 → 94pt cells, 86pt visible tiles, 8pt gaps
    private var panel: NSPanel?
    private var titlePanel: NSPanel?

    private func share(_ name: NSSharingService.Name) -> ([URL]) -> Void {
        { urls in NSSharingService(named: name)?.perform(withItems: urls) }
    }

    private func makeTiles() -> [(String, NSImage?, ([URL]) -> Void)] {
        [
            ("AirDrop", NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"),
             share(.sendViaAirDrop)),
            ("Messages", appIcon("com.apple.MobileSMS"), share(.composeMessage)),
            ("Mail", appIcon("com.apple.mail"), share(.composeEmail)),
            ("Copy", NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 26, weight: .regular)), { urls in
                let pb = NSPasteboard.general
                pb.clearContents(); pb.writeObjects(urls as [NSURL]) // paste in Finder/chat apps
            }),
        ]
    }

    /// Show the 2×2 grid just above-right of the shelf.
    func show(above shelf: NSRect) {
        hide()
        let side = Self.side, cols = 2, rows = 2
        let cellW = (side - 8) / CGFloat(cols), cellH = (side - 8) / CGFloat(rows)
        let size = NSSize(width: side, height: side)
        var origin = NSPoint(x: shelf.midX - 30, y: shelf.maxY - 20)
        if let vis = NSScreen.main?.visibleFrame { // keep on screen
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(origin.y, vis.maxY - size.height - 34)
        }
        let p = makePanel(size: size, at: origin)
        let card = makeCard(size: size)
        for (i, (title, icon, action)) in makeTiles().enumerated() {
            let col = CGFloat(i % cols), row = CGFloat(rows - 1 - i / cols)
            let tile = ActionTile(frame: NSRect(x: 4 + col * cellW, y: 4 + row * cellH, width: cellW, height: cellH),
                                  title: title, icon: icon, perform: action)
            tile.onDone = { [weak self] in self?.hide() }
            tile.onHover = { [weak self] t in self?.showTitle(t?.title) }
            card.addSubview(tile)
        }
        p.contentView = card
        p.orderFrontRegardless()
        panel = p
    }

    /// Floating pill above the grid naming the hovered tile.
    private func showTitle(_ text: String?) {
        titlePanel?.orderOut(nil); titlePanel = nil
        guard let text, let grid = panel?.frame else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 24, height: 26)
        let p = makePanel(size: size, at: NSPoint(x: grid.midX - size.width / 2, y: grid.maxY + 8))
        let card = makeCard(size: size, radius: 13)
        label.frame.origin = NSPoint(x: 12, y: (26 - label.frame.height) / 2)
        card.addSubview(label)
        p.contentView = card
        p.orderFrontRegardless()
        titlePanel = p
    }

    func hide() { showTitle(nil); panel?.orderOut(nil); panel = nil }
}

// MARK: - App

/// 3 shake sensitivity presets + Off. Index 1 (Low) = default.
enum Sensitivity: Int, CaseIterable {
    case off, low, medium, high
    var title: String { ["Off", "Low", "Medium", "High"][rawValue] }
    var preset: (needed: Int, minTravel: CGFloat)? {
        switch self { case .off: nil; case .low: (4, 20); case .medium: (3, 12); case .high: (1, 5) }
    }
    static var current: Sensitivity {
        get { Sensitivity(rawValue: UserDefaults.standard.object(forKey: "shakeSensitivity") as? Int ?? 1) ?? .low }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "shakeSensitivity") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shake = ShakeDetector()
    private var dragStartCount = 0
    private var armed = false

    func applicationDidFinishLaunching(_ n: Notification) {
        applySensitivity()
        // Mouse events don't need Accessibility permission (only key events do).
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.handle(e)
        }
        // ponytail: personal tool, --demo just pops the UI for a screenshot
        if CommandLine.arguments.contains("--demo"), let f = NSScreen.main?.visibleFrame {
            let desk = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
            let files = (try? FileManager.default.contentsOfDirectory(at: desk, includingPropertiesForKeys: nil))?
                .filter { !$0.lastPathComponent.hasPrefix(".") }.prefix(5) ?? []
            let shelf = Shelf(at: NSPoint(x: f.midX - 250, y: f.midY), urls: Array(files))
            InstantActions.shared.show(above: shelf.panel.frame)
            Shelf(at: NSPoint(x: f.midX + 200, y: f.midY), urls: Array(files)).setExpanded(true)
        }
    }

    private func handle(_ e: NSEvent) {
        let dragPB = NSPasteboard(name: .drag)
        switch e.type {
        case .leftMouseDown:
            guard Sensitivity.current != .off else { return }
            dragStartCount = dragPB.changeCount; shake.reset(); armed = true
        case .leftMouseDragged:
            // Drag pasteboard changes only when something is actually being dragged (file, text…)
            guard armed, dragPB.changeCount != dragStartCount else { return }
            if shake.feed(x: NSEvent.mouseLocation.x, t: e.timestamp) {
                armed = false
                let shelf = Shelf(at: NSEvent.mouseLocation)
                InstantActions.shared.show(above: shelf.panel.frame)
            }
        default:
            armed = false
            // drag ended somewhere — tiles are only useful mid-drag; delay so a drop on a tile lands first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { InstantActions.shared.hide() }
        }
    }

    private func applySensitivity() {
        guard let p = Sensitivity.current.preset else { return }
        shake.needed = p.needed; shake.minTravel = p.minTravel
    }

    // Right-click Dock icon → shake sensitivity (no menu bar icon on purpose)
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Shake to Open", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for s in Sensitivity.allCases {
            let item = NSMenuItem(title: s.title, action: #selector(pickSensitivity(_:)), keyEquivalent: "")
            item.tag = s.rawValue
            item.target = self
            item.state = s == Sensitivity.current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    @objc private func pickSensitivity(_ item: NSMenuItem) {
        Sensitivity.current = Sensitivity(rawValue: item.tag) ?? .low
        applySensitivity()
    }

    // Click Dock icon → empty shelf at cursor
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        _ = Shelf(at: NSEvent.mouseLocation); return false
    }

    // Drop files on Dock icon → shelf with those files
    func application(_ app: NSApplication, open urls: [URL]) {
        _ = Shelf(at: NSEvent.mouseLocation, urls: urls)
    }
}

if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

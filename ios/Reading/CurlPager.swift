import SwiftUI
import UIKit

/// Page turning with Apple's page-curl animation (like Apple Books), with
/// pinch-to-zoom on the whole screen (both pages together in landscape).
///
/// Two-page mode is laid out like a real book: an empty page beside the
/// cover, then [2,3], [4,5] … with the spine in the middle. Manga runs
/// right-to-left: the pager shows the book "backwards" so UIKit's forward
/// curl becomes going back, and page order within a spread is mirrored.
struct CurlPager: UIViewControllerRepresentable {
    let total: Int
    let two: Bool
    let rtl: Bool
    let compact: Bool                   // artwork: smaller margins, no page numbers
    @Binding var spread: Int?           // logical spread index (reading order)
    let renderer: PageRenderer
    let dark: Bool
    let invert: Bool                    // night-mode colour flip for text pages
    let aspect: CGFloat
    let onTap: (CGFloat) -> Void        // x position as a fraction of the width

    /// Sides of the book. Two-page mode has a blank slot before the cover (and one at the end if needed).
    var slotCount: Int { two ? ((total + 1) + 1) / 2 * 2 : total }
    var spreadCount: Int { two ? slotCount / 2 : total }

    /// Virtual = what UIKit sees. Reversed for right-to-left books.
    func virtualSpread(_ i: Int) -> Int { rtl ? spreadCount - 1 - i : i }
    func page(forVirtualSlot v: Int) -> Int? {
        let s = rtl ? slotCount - 1 - v : v
        if !two { return s }
        let p = s - 1
        return (p >= 0 && p < total) ? p : nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> BookContainer {
        let spine: UIPageViewController.SpineLocation = two ? .mid : .min
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                       options: [.spineLocation: NSNumber(value: spine.rawValue)])
        pvc.isDoubleSided = two
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = Coordinator.background(dark)
        // Our own tap zones (left / middle / right) instead of UIKit's edge taps.
        for g in pvc.gestureRecognizers where g is UITapGestureRecognizer { g.isEnabled = false }

        let c = context.coordinator
        let container = BookContainer(pvc: pvc, coordinator: c)
        c.container = container
        c.pvc = pvc
        c.current = virtualSpread(spread ?? 0)
        pvc.setViewControllers(c.controllers(forVirtualSpread: c.current), direction: .forward, animated: false)
        return container
    }

    func updateUIViewController(_ container: BookContainer, context: Context) {
        let c = context.coordinator
        let restyle = c.parent.dark != dark || c.parent.invert != invert || c.parent.aspect != aspect
        c.parent = self
        if restyle {
            container.view.backgroundColor = Coordinator.background(dark)
            c.pvc?.view.backgroundColor = Coordinator.background(dark)
            for vc in c.visible { vc.restyle(dark: dark, invert: invert, aspect: aspect) }
        }
        if let s = spread {
            let v = virtualSpread(s)
            if v != c.current { c.go(to: v) }
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: CurlPager
        weak var pvc: UIPageViewController?
        weak var container: BookContainer?
        var current = 0                  // virtual spread on screen
        private var animating = false
        private var pending: Int?
        private(set) var zoomed = false

        init(_ parent: CurlPager) { self.parent = parent }

        static func background(_ dark: Bool) -> UIColor {
            dark ? .black : UIColor(red: 0.95, green: 0.945, blue: 0.93, alpha: 1)
        }

        var visible: [PageSlotController] {
            (pvc?.viewControllers ?? []).compactMap { $0 as? PageSlotController }
        }

        func make(slot v: Int) -> PageSlotController {
            let side: PageSlotController.Side = parent.two ? (v % 2 == 0 ? .left : .right) : .single
            let vc = PageSlotController(slot: v, page: parent.page(forVirtualSlot: v), total: parent.total,
                                        renderer: parent.renderer, side: side, compact: parent.compact)
            vc.restyle(dark: parent.dark, invert: parent.invert, aspect: parent.aspect)
            vc.zoom = container?.zoomScale ?? 1
            return vc
        }

        func controllers(forVirtualSpread i: Int) -> [UIViewController] {
            parent.two ? [make(slot: i * 2), make(slot: i * 2 + 1)] : [make(slot: i)]
        }

        /// Turn (with the curl) to a virtual spread, e.g. after a tap, arrow key or contents jump.
        func go(to v: Int) {
            guard let pvc else { return }
            if animating { pending = v; return }
            container?.resetZoom()
            let dir: UIPageViewController.NavigationDirection = v >= current ? .forward : .reverse
            current = v
            animating = true
            pvc.setViewControllers(controllers(forVirtualSpread: v), direction: dir, animated: true) { [weak self] _ in
                DispatchQueue.main.async { self?.finishedAnimating() }
            }
        }

        private func finishedAnimating() {
            animating = false
            if let p = pending {
                pending = nil
                if p != current { go(to: p) }
            }
        }

        // MARK: Data source (finger swipes)

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard !zoomed, let v = vc as? PageSlotController, v.slot > 0 else { return nil }
            return make(slot: v.slot - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard !zoomed, let v = vc as? PageSlotController, v.slot + 1 < parent.slotCount else { return nil }
            return make(slot: v.slot + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pending: [UIViewController]) {
            animating = true
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            if completed, let first = pvc.viewControllers?.first as? PageSlotController {
                let v = parent.two ? first.slot / 2 : first.slot
                current = v
                let logical = parent.virtualSpread(v)
                DispatchQueue.main.async { self.parent.spread = logical }
            }
            finishedAnimating()
        }

        // MARK: Zoom & taps

        func setZoomed(_ z: Bool) {
            zoomed = z
            // While zoomed, one finger moves around the page instead of turning it.
            for g in pvc?.gestureRecognizers ?? [] where g is UIPanGestureRecognizer { g.isEnabled = !z }
        }

        func zoomEnded(_ scale: CGFloat) {
            for vc in visible { vc.zoom = scale }
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            if zoomed {
                // Tapping while zoomed in just steps back out.
                container?.resetZoom(animated: true)
                return
            }
            parent.onTap(g.location(in: v).x / max(v.bounds.width, 1))
        }
    }
}

/// Holds the page curl inside a zoomable scroll view so pinching zooms
/// everything on screen at once.
final class BookContainer: UIViewController, UIScrollViewDelegate {
    let pvc: UIPageViewController
    private let scroll = UIScrollView()
    private weak var coordinator: CurlPager.Coordinator?

    var zoomScale: CGFloat { scroll.zoomScale }

    init(pvc: UIPageViewController, coordinator: CurlPager.Coordinator) {
        self.pvc = pvc
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = pvc.view.backgroundColor
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.isEnabled = false   // only pans when zoomed in
        view.addSubview(scroll)
        addChild(pvc)
        scroll.addSubview(pvc.view)
        pvc.didMove(toParent: self)

        if let coordinator {
            let tap = UITapGestureRecognizer(target: coordinator, action: #selector(CurlPager.Coordinator.tapped(_:)))
            view.addGestureRecognizer(tap)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scroll.frame != view.bounds {
            scroll.setZoomScale(1, animated: false)
            scroll.frame = view.bounds
            pvc.view.frame = view.bounds
            scroll.contentSize = view.bounds.size
        }
    }

    func resetZoom(animated: Bool = false) {
        guard scroll.zoomScale != 1 else { return }
        scroll.setZoomScale(1, animated: animated)
        if !animated { scrollViewDidZoom(scroll); coordinator?.zoomEnded(1) }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pvc.view }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let z = scroll.zoomScale > 1.01
        scroll.panGestureRecognizer.isEnabled = z
        if z != coordinator?.zoomed { coordinator?.setZoomed(z) }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        coordinator?.zoomEnded(scale)
    }
}

/// One side of the book: a page image (or blank paper) plus its page number.
final class PageSlotController: UIViewController {
    enum Side { case left, right, single }

    let slot: Int
    let page: Int?
    let total: Int
    let renderer: PageRenderer
    let side: Side
    let compact: Bool

    private var dark = true
    private var invert = true
    private var aspect: CGFloat = 2.0 / 3.0
    /// Current zoom of the whole view; pages are redrawn sharper when zoomed.
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { render() } } }

    private let imageView = UIImageView()
    private let label = UILabel()
    private var pageRect = CGRect.zero
    private var lastKey = ""
    private var renderTask: Task<Void, Never>?

    init(slot: Int, page: Int?, total: Int, renderer: PageRenderer, side: Side, compact: Bool) {
        self.slot = slot
        self.page = page
        self.total = total
        self.renderer = renderer
        self.side = side
        self.compact = compact
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { renderTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(imageView)
        imageView.contentMode = .scaleAspectFit
        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        label.textAlignment = .center
        if let page, !compact { label.text = "\(page + 1) of \(total)" }
        view.addSubview(label)
        applyColors()
    }

    func restyle(dark: Bool, invert: Bool, aspect: CGFloat) {
        let changed = dark != self.dark || invert != self.invert || aspect != self.aspect
        self.dark = dark
        self.invert = invert
        self.aspect = aspect
        guard changed, isViewLoaded else { return }
        applyColors()
        lastKey = ""
        view.setNeedsLayout()
        render()
    }

    private func applyColors() {
        view.backgroundColor = CurlPager.Coordinator.background(dark)
        imageView.layer.shadowColor = UIColor.black.cgColor
        imageView.layer.shadowOpacity = dark ? 0 : 0.12
        imageView.layer.shadowRadius = 10
        imageView.layer.shadowOffset = CGSize(width: 0, height: 4)
        label.textColor = dark ? UIColor(white: 0.56, alpha: 1) : UIColor(white: 0.45, alpha: 1)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        guard b.width > 1, b.height > 1 else { return }
        let top: CGFloat = compact ? 10 : 44
        let bottom: CGFloat = compact ? 14 : 54
        let outer: CGFloat = compact ? 8 : (b.width < 420 ? 12 : 56)
        let spineGap: CGFloat = compact ? 0 : 6
        let availH = b.height - top - bottom
        let availW = side == .single ? b.width - outer * 2 : b.width - outer - spineGap
        let ph = max(1, min(availH, availW / aspect)).rounded(.down)
        let pw = (ph * aspect).rounded(.down)
        let x: CGFloat
        switch side {
        case .left: x = b.width - pw - spineGap       // hugs the spine
        case .right: x = spineGap
        case .single: x = ((b.width - pw) / 2).rounded()
        }
        let rect = CGRect(x: x, y: (top + (availH - ph) / 2).rounded(), width: pw, height: ph)
        if rect != pageRect {
            pageRect = rect
            imageView.frame = rect
            label.frame = CGRect(x: rect.minX, y: rect.maxY + 18, width: rect.width, height: 14)
            render()
        }
    }

    private func render() {
        guard let page, pageRect.width > 1, isViewLoaded else { return }
        let bucket = zoom > 1.4 ? min((zoom * 2).rounded() / 2, 3) : 1
        let scale = min(view.traitCollection.displayScale, 2) * bucket
        let size = pageRect.size
        let flip = dark && invert
        let key = "\(Int(size.width))x\(Int(size.height))|\(flip)|\(scale)"
        guard key != lastKey else { return }
        lastKey = key
        renderTask?.cancel()
        renderTask = Task { [weak self, renderer] in
            let img = await renderer.image(index: page, fitting: size, scale: scale, dark: flip)
            guard !Task.isCancelled, let self, let img else { return }
            self.imageView.image = img
        }
    }
}

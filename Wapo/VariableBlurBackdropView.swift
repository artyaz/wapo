//
//  VariableBlurBackdropView.swift
//  Wapo
//
//  True variable-blur backdrop for macOS using CABackdropLayer + CAFilter.
//  The blur amount is driven by a feathered rectangular mask image so the
//  surface reads like a soft rectangular field around the content, not a slab.
//

import SwiftUI
import AppKit
import QuartzCore

struct VariableBlurBackdrop: NSViewRepresentable {
    var maxBlurRadius: CGFloat = 34
    var featherRadius: CGFloat = 64

    func makeNSView(context: Context) -> VariableBlurBackdropHostView {
        VariableBlurBackdropHostView(
            maxBlurRadius: maxBlurRadius,
            featherRadius: featherRadius
        )
    }

    func updateNSView(_ nsView: VariableBlurBackdropHostView, context: Context) {
        nsView.update(
            maxBlurRadius: maxBlurRadius,
            featherRadius: featherRadius
        )
    }
}

final class VariableBlurBackdropHostView: NSView {
    private var backdropLayerRef: CALayer?
    private var variableBlurFilter: NSObject?
    private var maxBlurRadius: CGFloat
    private var featherRadius: CGFloat

    init(maxBlurRadius: CGFloat, featherRadius: CGFloat) {
        self.maxBlurRadius = maxBlurRadius
        self.featherRadius = featherRadius
        super.init(frame: .zero)
        configure()
        setupVariableBlur()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayerRef?.frame = bounds
        updateMaskImage()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        backdropLayerRef?.setValue(window.backingScaleFactor, forKey: "scale")
    }

    func update(maxBlurRadius: CGFloat, featherRadius: CGFloat) {
        self.maxBlurRadius = maxBlurRadius
        self.featherRadius = featherRadius
        variableBlurFilter?.setValue(maxBlurRadius, forKey: "inputRadius")
        updateMaskImage()
    }

    private func configure() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }

    private func setupVariableBlur() {
        guard let rootLayer = layer else { return }
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }
        guard let filterClass = NSClassFromString("CAFilter") as? NSObject.Type else { return }

        let selector = NSSelectorFromString("filterWithType:")
        guard filterClass.responds(to: selector),
              let result = filterClass.perform(selector, with: "variableBlur"),
              let blur = result.takeUnretainedValue() as? NSObject else {
            return
        }

        blur.setValue(maxBlurRadius, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")

        let backdrop = backdropClass.init()
        backdrop.frame = bounds
        backdrop.isOpaque = false
        backdrop.masksToBounds = false
        backdrop.setValue(true, forKey: "allowsGroupBlending")
        backdrop.allowsGroupOpacity = true
        backdrop.allowsEdgeAntialiasing = false
        backdrop.setValue(true, forKey: "disablesOccludedBackdropBlurs")
        backdrop.setValue(false, forKey: "ignoresOffscreenGroups")
        backdrop.setValue(false, forKey: "allowsInPlaceFiltering")
        backdrop.setValue(0.1, forKey: "bleedAmount")
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.filters = [blur]

        rootLayer.addSublayer(backdrop)

        backdropLayerRef = backdrop
        variableBlurFilter = blur
        updateMaskImage()
    }

    private func updateMaskImage() {
        guard bounds.width > 0,
              bounds.height > 0,
              let maskImage = makeMaskImage(for: bounds.size) else {
            return
        }
        variableBlurFilter?.setValue(maskImage, forKey: "inputMaskImage")
    }

    private func makeMaskImage(for size: CGSize) -> CGImage? {
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let feather = min(featherRadius, min(CGFloat(width), CGFloat(height)) / 2)
        let centerRect = rect.insetBy(dx: feather, dy: feather)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(rect)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(centerRect)

        drawEdgeGradients(in: context, rect: rect, centerRect: centerRect, feather: feather)
        drawCornerGradients(in: context, rect: rect, feather: feather)

        return context.makeImage()
    }

    private func drawEdgeGradients(
        in context: CGContext,
        rect: CGRect,
        centerRect: CGRect,
        feather: CGFloat
    ) {
        drawLinearGradient(
            in: context,
            rect: CGRect(x: centerRect.minX, y: centerRect.maxY, width: centerRect.width, height: feather),
            start: CGPoint(x: rect.midX, y: centerRect.maxY),
            end: CGPoint(x: rect.midX, y: rect.maxY)
        )

        drawLinearGradient(
            in: context,
            rect: CGRect(x: centerRect.minX, y: 0, width: centerRect.width, height: feather),
            start: CGPoint(x: rect.midX, y: centerRect.minY),
            end: CGPoint(x: rect.midX, y: rect.minY)
        )

        drawLinearGradient(
            in: context,
            rect: CGRect(x: 0, y: centerRect.minY, width: feather, height: centerRect.height),
            start: CGPoint(x: centerRect.minX, y: rect.midY),
            end: CGPoint(x: rect.minX, y: rect.midY)
        )

        drawLinearGradient(
            in: context,
            rect: CGRect(x: centerRect.maxX, y: centerRect.minY, width: feather, height: centerRect.height),
            start: CGPoint(x: centerRect.maxX, y: rect.midY),
            end: CGPoint(x: rect.maxX, y: rect.midY)
        )
    }

    private func drawCornerGradients(
        in context: CGContext,
        rect: CGRect,
        feather: CGFloat
    ) {
        let corners: [(CGPoint, CGRect)] = [
            (CGPoint(x: feather, y: feather), CGRect(x: 0, y: 0, width: feather, height: feather)),
            (CGPoint(x: rect.maxX - feather, y: feather), CGRect(x: rect.maxX - feather, y: 0, width: feather, height: feather)),
            (CGPoint(x: feather, y: rect.maxY - feather), CGRect(x: 0, y: rect.maxY - feather, width: feather, height: feather)),
            (CGPoint(x: rect.maxX - feather, y: rect.maxY - feather), CGRect(x: rect.maxX - feather, y: rect.maxY - feather, width: feather, height: feather)),
        ]

        corners.forEach { center, cornerRect in
            drawRadialGradient(
                in: context,
                rect: cornerRect,
                center: center,
                radius: feather
            )
        }
    }

    private func drawLinearGradient(
        in context: CGContext,
        rect: CGRect,
        start: CGPoint,
        end: CGPoint
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.cgColor, NSColor.clear.cgColor] as CFArray,
            locations: [0, 1]
        ) else {
            return
        }

        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    private func drawRadialGradient(
        in context: CGContext,
        rect: CGRect,
        center: CGPoint,
        radius: CGFloat
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [NSColor.white.cgColor, NSColor.clear.cgColor] as CFArray,
            locations: [0, 1]
        ) else {
            return
        }

        context.saveGState()
        context.addRect(rect)
        context.clip()
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }
}

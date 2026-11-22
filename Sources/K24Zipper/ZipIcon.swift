import AppKit
import SwiftUI

/// Blue document with a zipper and a "ZIP" label, used in the header and as the app icon.
struct ZipIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let w = s * 0.78, h = s * 0.96
            ZStack {
                DocShape(fold: w * 0.26)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.52, blue: 1.0),
                                                  Color(red: 0.0, green: 0.36, blue: 0.9)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.18), radius: s * 0.02, y: s * 0.01)
                FoldShape(fold: w * 0.26)
                    .fill(Color.white.opacity(0.35))
                // Zipper teeth
                VStack(spacing: s * 0.018) {
                    ForEach(0..<6, id: \.self) { i in
                        Capsule()
                            .fill(Color.white)
                            .frame(width: s * 0.07, height: s * 0.028)
                            .offset(x: i.isMultiple(of: 2) ? -s * 0.022 : s * 0.022)
                    }
                    RoundedRectangle(cornerRadius: s * 0.02)
                        .stroke(Color.white, lineWidth: s * 0.022)
                        .frame(width: s * 0.075, height: s * 0.12)
                }
                .offset(y: -h * 0.18)
                Text("ZIP")
                    .font(.system(size: s * 0.2, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: h * 0.3)
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct DocShape: Shape {
    let fold: CGFloat
    func path(in r: CGRect) -> Path {
        let radius = r.width * 0.1
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

private struct FoldShape: Shape {
    let fold: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX - fold, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - fold, y: r.minY + fold * 0.8))
        p.addQuadCurve(to: CGPoint(x: r.maxX - fold * 0.8, y: r.minY + fold),
                       control: CGPoint(x: r.maxX - fold, y: r.minY + fold))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + fold))
        p.closeSubpath()
        return p
    }
}

/// App icon: a zipped file being squeezed by two arrows (compression).
struct AppIconView: View {
    private let blueTop = Color(red: 0.20, green: 0.56, blue: 1.0)
    private let blueBottom = Color(red: 0.02, green: 0.30, blue: 0.86)
    private let amber = Color(red: 1.0, green: 0.72, blue: 0.10)
    private let amberDeep = Color(red: 1.0, green: 0.52, blue: 0.0)

    var body: some View {
        ZStack {
            // Tile
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [blueTop, blueBottom], startPoint: .top, endPoint: .bottom))
                .frame(width: 824, height: 824)
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 4)
                )
                .shadow(color: .black.opacity(0.3), radius: 22, y: 12)

            // Squashed file block with a zipper
            ZStack {
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.88)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                // Horizontal "pressed" lines
                VStack(spacing: 30) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(Color(red: 0.75, green: 0.82, blue: 0.95)).frame(width: 330, height: 14)
                    }
                }
                // Zipper teeth along the middle
                HStack(spacing: 10) {
                    ForEach(0..<9, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(blueBottom)
                            .frame(width: 22, height: 34)
                            .offset(y: i.isMultiple(of: 2) ? -9 : 9)
                    }
                    // Zipper pull
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(blueBottom).frame(width: 70, height: 52)
                        RoundedRectangle(cornerRadius: 8).fill(Color.white).frame(width: 34, height: 18)
                    }
                    .padding(.leading, 6)
                }
            }
            .frame(width: 560, height: 250)

            // Arrows pressing in from top and bottom
            CompressArrow()
                .fill(LinearGradient(colors: [amber, amberDeep], startPoint: .top, endPoint: .bottom))
                .frame(width: 230, height: 190)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
                .offset(y: -258)
            CompressArrow()
                .fill(LinearGradient(colors: [amber, amberDeep], startPoint: .top, endPoint: .bottom))
                .frame(width: 230, height: 190)
                .rotationEffect(.degrees(180))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 5)
                .offset(y: 258)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Downward-pointing block arrow.
private struct CompressArrow: Shape {
    func path(in r: CGRect) -> Path {
        let shaftW = r.width * 0.42
        let headH = r.height * 0.52
        var p = Path()
        p.move(to: CGPoint(x: r.midX - shaftW / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + shaftW / 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX + shaftW / 2, y: r.maxY - headH))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - headH))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - headH))
        p.addLine(to: CGPoint(x: r.midX - shaftW / 2, y: r.maxY - headH))
        p.closeSubpath()
        return p
    }
}

@MainActor
enum IconExporter {
    static func image(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = size / 1024
        return renderer.nsImage
    }

    static func export(to url: URL) -> Bool {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

import AppKit
import SwiftUI

struct StudioMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 52, y: 10)); path.addLine(to: CGPoint(x: 25, y: 10))
        path.addCurve(to: CGPoint(x: 12, y: 23), control1: CGPoint(x: 17, y: 10), control2: CGPoint(x: 12, y: 15))
        path.addLine(to: CGPoint(x: 12, y: 41))
        path.addCurve(to: CGPoint(x: 25, y: 54), control1: CGPoint(x: 12, y: 49), control2: CGPoint(x: 17, y: 54))
        path.addLine(to: CGPoint(x: 52, y: 54))
        path.move(to: CGPoint(x: 50, y: 22)); path.addLine(to: CGPoint(x: 34, y: 22))
        path.addCurve(to: CGPoint(x: 28, y: 28), control1: CGPoint(x: 30, y: 22), control2: CGPoint(x: 28, y: 24))
        path.addCurve(to: CGPoint(x: 34, y: 34), control1: CGPoint(x: 28, y: 32), control2: CGPoint(x: 30, y: 34))
        path.addLine(to: CGPoint(x: 42, y: 34))
        path.addCurve(to: CGPoint(x: 48, y: 40), control1: CGPoint(x: 46, y: 34), control2: CGPoint(x: 48, y: 36))
        path.addCurve(to: CGPoint(x: 42, y: 46), control1: CGPoint(x: 48, y: 44), control2: CGPoint(x: 46, y: 46))
        path.addLine(to: CGPoint(x: 26, y: 46))
        let scale = min(rect.width, rect.height) / 64
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: rect.midX - 32 * scale, ty: rect.midY - 32 * scale))
    }
}

struct StudioLogo: View {
    var size: CGFloat = 32
    var body: some View {
        StudioMark().stroke(style: StrokeStyle(lineWidth: size * 6 / 64, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size).accessibilityLabel("Container Studio")
    }
}

#Preview("Studio logo") { HStack(spacing: 32) { StudioLogo(size: 32); StudioLogo(size: 64); StudioLogo(size: 120) }.foregroundStyle(Palette.accent).padding(32).preferredColorScheme(.dark) }
#Preview("Studio mark") { StudioMark().stroke(lineWidth: 6).frame(width: 120, height: 120).padding() }

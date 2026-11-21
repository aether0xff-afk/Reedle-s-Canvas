import SwiftUI

@MainActor
struct TutorCanvasNotice: View {
    @ObservedObject var projection: CanvasProjection
    let anchor: CGRect
    let obstacles: [CGRect]
    let text: String
    var review: (() -> Void)?

    @ScaledMetric(relativeTo: .callout) private var buttonWidth: CGFloat = 156
    @ScaledMetric(relativeTo: .callout) private var buttonHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .callout) private var feedbackWidth: CGFloat = 230
    @ScaledMetric(relativeTo: .callout) private var feedbackHeight: CGFloat = 84

    var body: some View {
        GeometryReader { geometry in
            let width = min(review == nil ? feedbackWidth : buttonWidth, geometry.size.width)
            let height = review == nil ? feedbackHeight : max(44, buttonHeight)
            let viewport = CGRect(origin: .zero, size: geometry.size)
            if let frame = TutorPlacement.notice(size: CGSize(width: width, height: height), beside: anchor,
                                                camera: projection.camera, obstacles: obstacles, viewport: viewport) {
                Group {
                    if let review {
                        Button(action: review) {
                            Label(text, systemImage: "pencil.tip")
                                .padding(.horizontal, 10)
                                .frame(width: frame.width, height: frame.height)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tutor.reviewOnCanvas")
                    } else {
                        Text(verbatim: text)
                            .lineLimit(3)
                            .padding(.horizontal, 12)
                            .frame(width: frame.width, height: frame.height, alignment: .leading)
                            .accessibilityIdentifier("tutor.followUpOnCanvas")
                    }
                }
                .font(.callout)
                .foregroundStyle(.primary)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.26))
                        .allowsHitTesting(false)
                }
                .position(x: frame.midX, y: frame.midY)
            }
        }
        .allowsHitTesting(review != nil)
    }
}
